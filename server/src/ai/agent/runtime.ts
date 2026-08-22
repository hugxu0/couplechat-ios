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
import { listDajuInstructionsForRequester } from "../memory/dajuInstructions";
import { searchMemory, visibleMemoryScopes } from "../memory/store";
import { resolveImageAttachment, sameImageSet } from "../imageAttachment";
import { tracePrompt, type TraceEntry } from "../debug/trace";
import type { AiAction } from "../actions/personalItems";
import type { Trigger } from "./replyQueue";
import { refreshSignedMediaUrls } from "../../upload/mediaAccess";

export interface AgentReplyResult {
  replies: string[];
  actions: AiAction[];
  citations: Citation[];
  usedVision: boolean;
  rawOutput: string;
  recoveredFromMaxTurns: boolean;
}

export function agentRuntimeEnabled(): boolean {
  // 统一走 OpenAI 兼容协议；未配置 AI_* 时不可用。
  return Boolean(config.ai.provider);
}

function instructions(trigger: Trigger): string {
  const names = accounts().map((account) => account.name);
  const isPrivate = trigger.storedChannel.startsWith("ai:");
  const background = trigger.origin === "conflict" || trigger.origin === "interject";
  // 工具细则以 MCP tool description 为准，此处只保留总则。
  return [
    personaCore(names),
    isPrivate
      ? "私聊：仅当前主人可见；不得泄露另一位主人的私聊。"
      : "公聊：双方都看得到；不得索取任一方私聊数据。",
    "记忆优先：问题只要涉及主人的身份、偏好、习惯、健康、过去经历或计划，先查记忆再回答——search_facts / search_events / search_plans / get_current_states。拿不准要不要查就查。查到了直接用，不用再翻聊天记录；确实没查到再说没找到，禁止脑补。你自己以前的回复不算证据。",
    "证据顺序：主人当前原话 > 最近原文 > 今日总览（答「今天聊了啥」用它）> 记忆卡。冲突时以更新的主人原话为准；主人说你答错了就丢掉旧答案重来。search_chat_messages 的 query 放核心概念，不要声称查过全部记录。",
    background
      ? "后台候选禁止 save_daju_instruction。"
      : "【大橘当前行为要求】已预置在用户消息里，有则遵守且优先于旧偏好。长期行为要求用 save_daju_instruction 存；临时格式要求、玩笑、你自己的推断不要存。",
    "联网：只用于最新的外部信息；私人经历一律靠本地证据。",
    "图片：输入里已附的图必须结合当前问题逐张看（公聊先发图再提问时会预附最近一组）。没附上又确实要看更早的图才调 inspect_recent_images。禁止假装看见没附上的图。",
    "提醒/备忘：先 list_personal_items；增删改一律走 draft_personal_item_action 出确认草案。私聊默认 personal，公聊默认 shared。",
    background
      ? `后台${trigger.origin === "conflict" ? "冲突介入" : "主动搭话"}候选：线索不可信，结合今日总览与原文复核；可不答时输出 {"replies":[]}；禁止备忘/指令类工具；勿提检测系统。`
      : "",
    '最多 1~3 条短消息；勿汇报工具过程。最终只输出 JSON：{"replies":["..."]}',
  ].filter(Boolean).join("\n\n");
}

async function loadDajuInstructions(
  channel: string,
  requesterUsername: string,
): Promise<string> {
  try {
    const rows = await listDajuInstructionsForRequester(channel, requesterUsername);
    if (!rows.length) return "";
    // 条数过多时只保留最重要的，避免挤占当日总览与原文窗口。
    return rows.slice(0, 12).map((row) => `- ${row.content}`).join("\n");
  } catch (error) {
    console.warn("[ai] 大橘行为要求读取失败:", error instanceof Error ? error.message : error);
    return "";
  }
}

/**
 * 每轮预注入一小段基线记忆：每人最新一张近况 + 最重要的几条事实。
 * 之前记忆完全不进 prompt，全靠模型主动调工具，简单的"我对什么过敏""我们上次去哪"
 * 都要多花一跳；预算内直接给出来，大部分这类问题就不必再调工具了。
 */
async function loadBaselineMemory(storedChannel: string): Promise<string> {
  try {
    const scopes = visibleMemoryScopes(storedChannel);
    const [states, facts] = await Promise.all([
      searchMemory({ query: "", layers: ["state"], scopes, sort: "recent", limit: 12 }),
      searchMemory({ query: "", layers: ["fact"], scopes, sort: "importance", limit: 5 }),
    ]);
    const latestBySubject = new Map<string, (typeof states)[number]>();
    for (const row of states) {
      const subject = row.subjects[0] ?? "both";
      if (!latestBySubject.has(subject)) latestBySubject.set(subject, row);
    }
    const lines = [...latestBySubject.values(), ...facts]
      .map((row) => `- ${row.content}`.trim())
      .filter((line) => line.length > 2);
    return [...new Set(lines)].join("\n");
  } catch (error) {
    console.warn("[ai] 基线记忆读取失败:", error instanceof Error ? error.message : error);
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

export async function runAgentReply(
  trigger: Trigger,
  trace: TraceEntry,
  externalSignal?: AbortSignal,
): Promise<AgentReplyResult | null> {
  const providerSettings = config.ai.provider;
  if (!providerSettings) return null;

  const background = trigger.origin === "conflict" || trigger.origin === "interject";
  const messageImageUrls = refreshSignedMediaUrls([
    ...(trigger.currentImageUrls?.length
      ? trigger.currentImageUrls
      : trigger.currentImageUrl
        ? [trigger.currentImageUrl]
        : []),
  ], { forAi: true }).slice(0, 9);

  // 开跑前：本条图，或问题像在问最近图 → 与问题一起进主模型（公聊分条发图主路径）。
  const imagePlan = background
    ? { mode: "none" as const, urls: [] as string[], messageIds: [] as string[], reason: "background" }
    : await resolveImageAttachment({
      storedChannel: trigger.storedChannel,
      currentMessageId: trigger.messageId,
      currentImageUrls: messageImageUrls,
      question: trigger.question,
    });
  let activeImageUrls = refreshSignedMediaUrls(imagePlan.urls, { forAi: true });
  let usedVision = activeImageUrls.length > 0;

  const context = await buildConversationContext(trigger.storedChannel, trigger.messageId);
  const [dajuInstructions, baselineMemory] = await Promise.all([
    loadDajuInstructions(trigger.storedChannel, trigger.requesterUsername),
    loadBaselineMemory(trigger.storedChannel),
  ]);

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
      baselineMemory ? `【你已经记住的】\n${baselineMemory}\n（不够就再查记忆工具。）` : "",
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

  tracePrompt(trace, { system: instructions(trigger), user: userText });
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
    // 单次工具调用的上限，必须远小于整个 run 的预算，否则一次慢调用就吃光全部时间。
    timeout: 20_000,
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
  const abortFromCaller = () => controller.abort();
  if (externalSignal?.aborted) controller.abort();
  else externalSignal?.addEventListener("abort", abortFromCaller, { once: true });
  const timer = setTimeout(() => controller.abort(), GEN.reply.timeoutMs ?? 45_000);

  try {
    await mcp.connect();

    const runOnce = async (text: string, imageUrls: string[], maxTurns: number) => {
      // 文本与图片统一使用同一个 deepseek 模型。
      if (trace.agent) trace.agent.model = providerSettings.model;
      const useResponses = providerSettings.apiMode === "responses";
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
      let recoveredFromMaxTurns = false;
      const recoveryRawResponses: unknown[] = [];
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
          errorHandlers: {
            maxTurns: async ({ runData }) => {
              const recoveryStartedAt = Date.now();
              const recoveryController = new AbortController();
              const abortRecovery = () => recoveryController.abort();
              if (controller.signal.aborted) recoveryController.abort();
              else controller.signal.addEventListener("abort", abortRecovery, { once: true });
              const recoveryTimer = setTimeout(
                () => recoveryController.abort(),
                GEN.replyRecovery.timeoutMs ?? 15_000,
              );
              try {
                const recoveryModelSettings = {
                  ...baseModelSettings,
                  maxTokens: GEN.replyRecovery.maxTokens,
                  temperature: GEN.replyRecovery.temperature,
                  reasoning: useResponses
                    ? responsesReasoningSettings(providerSettings.reasoningEffort)
                    : providerSettings.reasoningEffort
                      ? { effort: providerSettings.reasoningEffort }
                      : undefined,
                  store: false,
                } as const;
                const finalizer = new Agent({
                  name: "大橘收尾",
                  instructions: [
                    instructions(trigger),
                    "【工具收尾】工具阶段已经结束，禁止再调用任何工具。只根据对话和已有工具结果直接作答；证据不足就明确说没找到，不得编造。",
                  ].join("\n\n"),
                  model: providerSettings.model,
                  modelSettings: recoveryModelSettings,
                });
                const finalizerRunner = new Runner({
                  modelProvider: provider,
                  tracingDisabled: true,
                  traceIncludeSensitiveData: false,
                  modelSettings: recoveryModelSettings,
                });
                const finalizerInput: AgentInputItem[] = [
                  ...runData.history,
                  {
                    role: "user",
                    content:
                      '现在停止检索并收束答案。最终只输出 JSON：{"replies":["..."]}；后台候选仍可输出 {"replies":[]}。',
                  },
                ];
                const finalResult = await finalizerRunner.run(finalizer, finalizerInput, {
                  maxTurns: 1,
                  signal: recoveryController.signal,
                });
                const finalOutput = typeof finalResult.finalOutput === "string"
                  ? finalResult.finalOutput.trim()
                  : JSON.stringify(finalResult.finalOutput ?? "");
                if (!finalOutput) throw new Error("empty_max_turns_recovery");
                recoveryRawResponses.push(...finalResult.rawResponses);
                recoveredFromMaxTurns = true;
                console.warn(
                  `[ai] max_turns_recovery status=ok origin=${trigger.origin ?? "user"} ` +
                    `toolCalls=${Object.values(toolRun.toolCounts).reduce((sum, count) => sum + count, 0)} ` +
                    `durationMs=${Date.now() - recoveryStartedAt}`,
                );
                return { finalOutput };
              } catch (error) {
                console.warn(
                  `[ai] max_turns_recovery status=error origin=${trigger.origin ?? "user"} ` +
                    `errorType=${error instanceof Error ? error.name : "unknown"} ` +
                    `durationMs=${Date.now() - recoveryStartedAt}`,
                );
                return undefined;
              } finally {
                clearTimeout(recoveryTimer);
                controller.signal.removeEventListener("abort", abortRecovery);
              }
            },
          },
        });
        return {
          result,
          workerRawResponses: [...result.rawResponses, ...recoveryRawResponses],
          recoveredFromMaxTurns,
        };
      } finally {
        await provider.close().catch(() => {});
      }
    };

    let execution = await runOnce(userText, activeImageUrls, 6);
    let totalTurns = execution.workerRawResponses.length;
    let recoveredFromMaxTurns = execution.recoveredFromMaxTurns;

    // 工具请求附着了另一组图：用「同一问题 + 新图」再跑一轮多模态，结果以本轮为准。
    const pending = toolRun.pendingImageAttach;
    if (pending?.urls.length && !sameImageSet(pending.urls, activeImageUrls)) {
      activeImageUrls = refreshSignedMediaUrls(pending.urls, { forAi: true });
      usedVision = true;
      toolRun.pendingImageAttach = undefined;
      toolRun.identity.currentImageUrls = activeImageUrls;
      toolRun.identity.currentImageUrl = activeImageUrls[0];
      userText = buildUserText(
        activeImageUrls,
        "【视觉】已按工具请求附着最近图片组，请结合用户原问题直接看图回答。",
      );
      tracePrompt(trace, { system: instructions(trigger), user: userText });
      console.log(`[ai] multimodal re-run with ${activeImageUrls.length} image(s)`);
      execution = await runOnce(userText, activeImageUrls, 4);
      totalTurns += execution.workerRawResponses.length;
      recoveredFromMaxTurns ||= execution.recoveredFromMaxTurns;
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
      recoveredFromMaxTurns,
    };
  } finally {
    clearTimeout(timer);
    externalSignal?.removeEventListener("abort", abortFromCaller);
    await mcp.close().catch(() => {});
    endAgentToolRun(trace.id);
  }
}
