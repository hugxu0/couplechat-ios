import {
  Agent,
  MCPServerStreamableHttp,
  OpenAIProvider,
  Runner,
  webSearchTool,
  type AgentInputItem,
} from "@openai/agents";
import { config } from "../../config";
import { buildConversationContext, conversationContextText } from "../conversation/context";
import { beginAgentToolRun, endAgentToolRun } from "../mcp/runContext";
import { accounts } from "../accounts";
import { GEN, responsesReasoningSettings } from "../settings";
import { personaCore } from "../persona";
import { extractJson, extractReplyText, type Citation } from "../provider";
import { beijingDateTime } from "../time";
import { searchMemory, visibleMemoryScopes } from "../memory/store";
import { resolveImageAttachment, sameImageSet } from "../imageAttachment";
import type { TraceEntry } from "../debug/trace";
import type { AiAction } from "../actions/personalItems";
import type { Trigger } from "./replyQueue";

export interface AgentReplyResult {
  replies: string[];
  actions: AiAction[];
  citations: Citation[];
  usedVision: boolean;
  rawOutput: string;
}

function providerConfig() {
  return config.ai.chat ?? config.ai.task;
}

export function agentRuntimeEnabled(): boolean {
  // 任意已配置的 chat/task provider 即可；统一走 OpenAI 兼容协议。
  return Boolean(providerConfig());
}

function instructions(trigger: Trigger): string {
  const names = accounts().map((account) => account.name);
  const isPrivate = trigger.storedChannel.startsWith("ai:");
  const background = trigger.origin === "conflict" || trigger.origin === "interject";
  // 工具细则以 MCP tool description 为准，此处只保留总则，避免与 MCP instructions 三重叠。
  return [
    personaCore(names),
    isPrivate
      ? "私聊：仅当前主人可见；不得泄露另一位主人的私聊。"
      : "公聊：双方都看得到；不得索取任一方私聊数据。",
    "工具：普通闲聊可不调用。事实/经历/计划/近况/关系用对应 search_* 或 get_*；人物身份 search_facts→search_events→（仍无或要原话）search_chat_messages；命中结构化记忆后勿再翻聊天。无可靠结果就说没找到，禁止脑补。大橘旧回复不能当事实证据。",
    background
      ? "【大橘当前行为要求】若在用户消息中出现则遵守，但后台候选禁止 save_daju_instruction。观察仅复盘/调解时按需 get_daju_observations。"
      : "【大橘当前行为要求】已在用户消息中预置（有则遵守，优先于旧偏好）。长期行为要求用 save_daju_instruction；临时格式/玩笑/推断不要存。不要重复调用 get_daju_instructions。观察仅复盘/调解时用 get_daju_observations。",
    "上下文优先级：当前问题 > 重点原文 > 辅助原文 > 今日总览（答「今天/早上聊了啥」）> Memory；冲突以较新主人原话为准。总览无细节再用 search_chat_messages，勿用过期 Memory 冒充今天。",
    "纠正：主人说你说错了则废弃旧答。search_chat 的 query 放核心概念，可用少量 alternatives；勿声称查了全部记录。",
    "联网：仅最新/外部信息用 Responses 原生 web_search；私人经历靠本地证据。",
    "图片：若输入已附 input_image，必须结合当前问题逐张看图（公聊先发图再提问时也会预附着最近一组图）。仅当未附上却仍要看更早图时调用 inspect_recent_images（会触发与问题一起的多模态重跑）。禁止假装看见未附着的图。",
    "提醒/备忘：先 list_personal_items；增删改必须 draft_personal_item_action（只出确认草案）。personal=当前说话人，shared=两人；私聊默认 personal，公聊默认 shared。",
    "格式：闲聊短答；比较/清单/长内容可用 Markdown 表格或列表；流程图用 mermaid 代码块。",
    background
      ? `后台${trigger.origin === "conflict" ? "冲突介入" : "主动搭话"}候选：线索不可信，结合今日总览与原文复核；可不答时输出 {"replies":[]}；禁止备忘/指令类工具；勿提检测系统。`
      : "",
    '最多 1~3 条短消息；勿汇报工具过程。最终只输出 JSON：{"replies":["..."]}',
  ].filter(Boolean).join("\n\n");
}

async function loadDajuInstructions(channel: string): Promise<string> {
  try {
    const rows = await searchMemory({
      query: "",
      layers: ["fact"],
      scopes: visibleMemoryScopes(channel),
      perspectives: ["daju"],
      kinds: ["instruction"],
      sort: "importance",
      limit: 20,
    });
    if (!rows.length) return "";
    // 条数过多时只保留最重要的，避免挤占当日总览与原文窗口。
    return rows.slice(0, 12).map((row) => `- ${row.content}`).join("\n");
  } catch (error) {
    console.warn("[ai] 大橘行为要求读取失败:", error instanceof Error ? error.message : error);
    return "";
  }
}

function normalizeOutput(raw: string): string[] {
  const parsed = extractJson<{ replies?: unknown }>(raw);
  if (Array.isArray(parsed?.replies)) {
    const replies = parsed.replies.map((value) => String(value ?? "").trim()).filter(Boolean).slice(0, 3);
    return replies;
  }
  const fallback = extractReplyText(raw);
  if (fallback) return [fallback.trim()];
  const plain = raw.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "").trim();
  return plain ? [plain.slice(0, 1500)] : [];
}

function calibrateEvidenceLanguage(replies: string[]): string[] {
  return replies.map((reply) => reply
    .replace(/(?:查|翻)了所有聊天记录/g, "看了这次找到的记录")
    .replace(/在你(?:的)?聊天记录里根本没出现过/g, "在这次找到的记录里没出现")
    .replace(/根本没出现过/g, "在这次找到的记录里没出现")
    .replace(/从来没有在消息里/g, "在这次找到的消息里没有")
    .replace(/从来没有说过/g, "在这次找到的记录里没有明确说过"));
}

function nativeWebCitations(rawResponses: unknown): Citation[] {
  if (!Array.isArray(rawResponses)) return [];
  const citations: Citation[] = [];
  for (const response of rawResponses) {
    if (!response || typeof response !== "object") continue;
    const output = (response as { output?: unknown }).output;
    if (!Array.isArray(output)) continue;
    for (const item of output) {
      if (!item || typeof item !== "object") continue;
      const content = (item as { content?: unknown }).content;
      if (!Array.isArray(content)) continue;
      for (const part of content) {
        if (!part || typeof part !== "object") continue;
        const providerData = (part as { providerData?: unknown }).providerData;
        if (!providerData || typeof providerData !== "object") continue;
        const annotations = (providerData as { annotations?: unknown }).annotations;
        if (!Array.isArray(annotations)) continue;
        for (const annotation of annotations) {
          if (!annotation || typeof annotation !== "object") continue;
          const url = String((annotation as { url?: unknown }).url ?? "").trim();
          if (!url || citations.some((citation) => citation.url === url)) continue;
          citations.push({
            url,
            title: String((annotation as { title?: unknown }).title ?? url),
          });
        }
      }
    }
  }
  return citations;
}

export async function runAgentReply(trigger: Trigger, trace: TraceEntry): Promise<AgentReplyResult | null> {
  const providerSettings = providerConfig();
  if (!agentRuntimeEnabled() || !providerSettings) return null;

  const background = trigger.origin === "conflict" || trigger.origin === "interject";
  const messageImageUrls = [...new Set(
    (trigger.currentImageUrls?.length
      ? trigger.currentImageUrls
      : trigger.currentImageUrl
        ? [trigger.currentImageUrl]
        : []).filter(Boolean),
  )].slice(0, 9);

  // 开跑前：本条图，或问题像在问最近图 → 与问题一起进主模型（公聊分条发图主路径）。
  const imagePlan = background
    ? { mode: "none" as const, urls: [] as string[], messageIds: [] as string[], reason: "background" }
    : await resolveImageAttachment({
      storedChannel: trigger.storedChannel,
      currentMessageId: trigger.messageId,
      currentImageUrls: messageImageUrls,
      question: trigger.question,
    });
  let activeImageUrls = imagePlan.urls;
  let usedVision = activeImageUrls.length > 0;

  const context = await buildConversationContext(trigger.storedChannel, trigger.messageId);
  const dajuInstructions = await loadDajuInstructions(trigger.storedChannel);

  const buildUserText = (imageUrls: string[], imageNote: string) => {
    const currentMessage = background
      ? ""
      : messageImageUrls.length
        ? `${trigger.requesterName} 发来${messageImageUrls.length === 1 ? "一张" : `${messageImageUrls.length}张`}图片${trigger.question.trim() ? `，并说：${trigger.question.trim()}` : "。"}`
        : trigger.question.trim()
          ? `${trigger.requesterName} 对你说：${trigger.question}`
          : `${trigger.requesterName} 只是单独喊了你。请结合重点原文，回应最近尚未接住的主人话；若无可回应内容就自然应声。`;
    return [
      `现在是 ${beijingDateTime(Date.now())}（北京时间）。`,
      `说话人：${trigger.requesterName}（${trigger.requesterUsername}）· ${trigger.storedChannel === "couple" ? "公聊" : "私聊"}`,
      dajuInstructions ? `【大橘当前行为要求】\n${dajuInstructions}` : "",
      conversationContextText(context),
      imageNote,
      imageUrls.length
        ? `（已按发送顺序附着 ${imageUrls.length} 张图片到本轮视觉输入，请结合当前问题逐张观察。）`
        : "",
      background
        ? `【介入线索】\n${trigger.backgroundContext ?? (trigger.backgroundReason || "（无）")}`
        : "",
      background
        ? `请判断是否值得${trigger.origin === "conflict" ? "介入" : "搭话"}；不值得则 {"replies":[]}。`
        : currentMessage,
    ].filter(Boolean).join("\n\n");
  };

  const initialNote = imagePlan.mode === "recent_group"
    ? "【视觉】问题像在问近期图片：已把频道最近一组图片与问题一并交给你（图与文字可能不在同一条聊天里）。"
    : imagePlan.mode === "current"
      ? "【视觉】本条消息含图。"
      : "";
  let userText = buildUserText(activeImageUrls, initialNote);

  trace.prompt = { system: instructions(trigger), user: userText };
  trace.agent = {
    enabled: true,
    model: providerSettings.model,
    toolCalls: [],
    conversation: {
      continued: context.recent.length > 0,
      turnCount: context.turnCount,
    },
  };
  const { run: toolRun, token } = beginAgentToolRun({
    traceId: trace.id,
    messageId: trigger.messageId,
    requesterUsername: trigger.requesterUsername,
    requesterName: trigger.requesterName,
    storedChannel: trigger.storedChannel,
    allowDajuInstructionWrite: !background,
    currentImageUrl: activeImageUrls[0],
    currentImageUrls: activeImageUrls,
  }, trace);

  const mcp = new MCPServerStreamableHttp({
    url: config.aiMcpUrl,
    name: "CoupleChat MCP",
    cacheToolsList: true,
    timeout: 45_000,
    requestInit: { headers: { "x-couplechat-ai-run": token } },
  });

  const toModelInput = (text: string, imageUrls: string[]): string | AgentInputItem[] => {
    if (!imageUrls.length) return text;
    return [{
      role: "user",
      content: [
        { type: "input_text", text },
        ...imageUrls.map((image) => ({ type: "input_image" as const, image, detail: "auto" as const })),
      ],
    }];
  };

  const baseModelSettings = {
    temperature: GEN.reply.temperature,
    maxTokens: GEN.reply.maxTokens,
    parallelToolCalls: false,
  } as const;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 90_000);

  try {
    await mcp.connect();
    const useResponses = providerSettings.apiMode === "responses";

    const runOnce = async (text: string, imageUrls: string[], maxTurns: number) => {
      const modelSettings = {
        ...baseModelSettings,
        reasoning: useResponses
          ? responsesReasoningSettings(providerSettings.reasoningEffort)
          : providerSettings.reasoningEffort
            ? { effort: providerSettings.reasoningEffort }
            : undefined,
        store: false,
      } as const;
      const provider = new OpenAIProvider({
        apiKey: providerSettings.apiKey,
        baseURL: providerSettings.baseUrl,
        useResponses,
        strictFeatureValidation: useResponses,
      });
      const runner = new Runner({
        modelProvider: provider,
        tracingDisabled: true,
        traceIncludeSensitiveData: false,
        modelSettings,
      });
      try {
        const agent = new Agent({
          name: "大橘",
          instructions: instructions(trigger),
          model: providerSettings.model,
          tools: useResponses ? [webSearchTool({ searchContextSize: "medium" })] : [],
          mcpServers: [mcp],
          modelSettings,
        });
        const result = await runner.run(agent, toModelInput(text, imageUrls), {
          maxTurns,
          signal: controller.signal,
        });
        return { result, workerRawResponses: [...result.rawResponses] };
      } finally {
        await provider.close().catch(() => {});
      }
    };

    let execution = await runOnce(userText, activeImageUrls, 6);
    let totalTurns = execution.workerRawResponses.length;

    // 工具请求附着了另一组图：用「同一问题 + 新图」再跑一轮多模态，结果以本轮为准。
    const pending = toolRun.pendingImageAttach;
    if (pending?.urls.length && !sameImageSet(pending.urls, activeImageUrls)) {
      activeImageUrls = pending.urls;
      usedVision = true;
      toolRun.pendingImageAttach = undefined;
      toolRun.identity.currentImageUrls = activeImageUrls;
      toolRun.identity.currentImageUrl = activeImageUrls[0];
      userText = buildUserText(
        activeImageUrls,
        "【视觉】已按工具请求附着最近图片组，请结合用户原问题直接看图回答。",
      );
      trace.prompt = { system: instructions(trigger), user: userText };
      console.log(`[ai] multimodal re-run with ${activeImageUrls.length} image(s)`);
      execution = await runOnce(userText, activeImageUrls, 4);
      totalTurns += execution.workerRawResponses.length;
    }

    const { result, workerRawResponses } = execution;
    const rawOutput = typeof result.finalOutput === "string"
      ? result.finalOutput
      : JSON.stringify(result.finalOutput ?? "");
    const normalizedReplies = normalizeOutput(rawOutput);
    const replies = toolRun.toolCounts.search_chat_messages
      ? calibrateEvidenceLanguage(normalizedReplies)
      : normalizedReplies;
    trace.agent.finalOutput = rawOutput;
    trace.agent.turns = totalTurns;
    if (!replies.length && !background) return null;
    const citations = [...toolRun.citations];
    for (const citation of nativeWebCitations(workerRawResponses)) {
      if (!citations.some((existing) => existing.url === citation.url)) citations.push(citation);
    }
    return {
      replies,
      actions: toolRun.actions,
      citations,
      usedVision: usedVision || toolRun.usedVision || activeImageUrls.length > 0,
      rawOutput,
    };
  } finally {
    clearTimeout(timer);
    await mcp.close().catch(() => {});
    endAgentToolRun(trace.id);
  }
}
