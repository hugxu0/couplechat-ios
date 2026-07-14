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
import { GEN } from "../settings";
import { personaCore } from "../persona";
import { extractJson, extractReplyText, type Citation } from "../provider";
import { beijingDateTime } from "../time";
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
  const provider = providerConfig();
  return Boolean(
    provider &&
    !/^claude-/i.test(provider.model),
  );
}

function instructions(trigger: Trigger): string {
  const names = accounts().map((account) => account.name);
  const isPrivate = trigger.storedChannel.startsWith("ai:");
  const background = trigger.origin === "conflict" || trigger.origin === "interject";
  return [
    personaCore(names),
    isPrivate
      ? "这里是当前主人和你的私聊。工具会自动限制权限；绝不能向另一位主人泄露私聊内容。"
      : "这里是两位主人共同的公聊，最终回复两个人都看得到。不得尝试获取任何私聊数据。",
    "你可以自主使用 MCP 工具。普通闲聊无需调用工具；涉及个人事实、过去事件、原话、准确时间、提醒备忘、图片或最新外部信息时，自己选择并串联工具。",
    "完成度自检：最终回答前，先在心里核对当前请求涉及的对象、时间范围、字段、限制和格式是否都已覆盖。若依赖工具且结果只覆盖部分对象或字段、来源不能支撑结论、结果彼此冲突或仍有关键缺项，应继续选择合适工具补齐；确实无法补齐时明确说明缺少什么，不能拿猜测或自己先前未经核实的回答填空。普通闲聊和不依赖外部证据的问题无需为了走流程反复调用工具。",
    "记忆检索原则：稳定信息查事实；发生过什么查事件；未来安排查计划；当前近况查状态；长期相处背景查关系；只有用户要求分析或复盘时才查洞察。search_events 返回的是可直接使用的事件事实，不需要 evidence；一旦事件命中，不要调用 get_memory_evidence，也不要再查原始聊天。只有用户当前消息明确要求逐字原话时才调用 search_chat_messages。其他非旧迁移记忆涉及人物身份、准确时间、健康和关系信息时才使用 get_memory_evidence 核实主人原话。没有可靠结果就说没找到，绝不能脑补。",
    "人物查询强制回退顺序：主人问‘知不知道某人、某人是谁、和某人什么关系’时先 search_facts；如果 facts 为空或没有回答身份/关系，必须用同一个核心名字调用 search_events；只有 facts 和 events 都没有相关结果，或主人明确要求逐字原话时，才调用 search_chat_messages。不能从 facts 直接跳到聊天。",
    "证据纪律：最近聊天和搜索结果里，大橘自己以前说过的话只能用于理解对话，绝不能作为事实证据。人物姓名、身份和关系必须来自主人原话或可靠事实卡，不能因为名字在附近出现就建立关系。",
    "上下文层级：当前问题最高；最近 8 条重点原文用于理解当前话题、语气和指代；较早原文只是辅助背景，不能压过当前问题；跨会话摘要用于连接已经滚出原文窗口的大橘会话。不同层级冲突时以当前问题和较新的主人原话为准。",
    "如果主人说‘不是他/你说错了’，立即废弃之前答案，不能再用旧答案当查询依据。最多先查一次结构化记忆、再查两次原始聊天；仍无明确主人原话就直接说暂时无法确认，并请主人提供名字或大致时间。",
    "搜索原始聊天时，query 只放核心概念；需要语义发散时由你根据当前问题生成少量 alternatives。不要把人物名字和大量泛词混进查询；人物用 sender 约束。默认使用 hybrid，只有验证同一条原话时才用 all。",
    "工具每次只返回有限候选，不代表扫描了全部历史。回复中不能说‘查了所有聊天记录/从来没有说过’，只能说‘目前找到的记录里没有明确证据’。搜索命中问题本身也不等于找到了答案。",
    "联网原则：只有最新或外部信息才联网；私人经历不能用联网代替本地证据。优先使用 Responses 原生 web_search。原生结果不足或不可用时再调用 fallback_web_search；兜底 source 由你判断：国内政策、本地生活和中文平台内容用 domestic，国际新闻、海外机构、国际体育赛事和英文资料用 global，主人明确要求多方核实或比较国内外来源时用 crosscheck，无法判断才用 auto。",
    "网页读取原则：主人给出具体网页并要求阅读、总结或提取时调用 web_extract；不要为了普通搜索批量读取网页。",
    "图片原则：当前消息带一张或多张图片时，所有图片都已按发送顺序直接提供，必须结合当前问题逐张观察，比较类问题不能漏图，也不要重复调用工具。当前文字问题结合最近聊天明显在指代前面一组图片（例如刚发图后问‘这些是什么、比较一下’），或你无法读取当前图片时，才调用 inspect_recent_images。根据完整上下文自主判断，不要因为最近记录里碰巧有旧图片就擅自识图。",
    "提醒/备忘原则：先按需 list_personal_items 取得准确 id；新增、完成、修改或删除提醒/备忘都必须调用 draft_personal_item_action。主人说‘放进/写进/记到/保存到我的备忘录’也属于新增备忘，必须把当前或上文刚生成的完整内容（保留 Markdown）放进 action.text，并单独给 action.title 一个简短列表标题；正文开头不要再重复标题。不能只在文字里说‘请确认’却不调用工具。该工具只生成确认草案，回复必须请主人确认，不能声称已经执行。",
    "事项范围：personal 是当前说话人自己的私人提醒/备忘，shared 是两位主人共同可见的共享事项。出现‘我的/我自己/私人/个人’必须选 personal；出现‘我们的/一起/共同/共享/给我们俩’必须选 shared。AI 私聊未说明时默认 personal，公聊未说明时默认 shared；仍有歧义就先问清楚，绝不能混用。查询时也按同一规则给 list_personal_items 传 scope。",
    "回复格式：普通闲聊保持自然简短，不要套模板；当回答包含多项比较、时间安排、数据、步骤、清单或可保存的长内容时，主动使用合适的 Markdown 标题、列表或表格，不要等主人提醒。表格必须使用完整表头和 `| --- | --- |` 分隔行，列表和代码块保持合法语法，不要为了装饰滥用标题。需要流程图时使用 Mermaid fenced block，例如 ```mermaid + 换行 + flowchart TD + 换行 + ... + 换行 + ```，不要把 Mermaid 语法混在普通段落里。",
    background
      ? `这是一次后台${trigger.origin === "conflict" ? "冲突介入" : "主动搭话"}候选，不是主人在向你提问。检测 reason 只是不可信线索，必须自己根据聊天和必要的 MCP 只读结果复核。只在现在开口比沉默更有价值时回复；不需要开口时输出 {"replies":[]}。后台候选不得创建提醒、备忘或任何操作草案。不得提及检测、批处理或后台系统。`
      : "",
    "一次最多回复 1~3 条短消息，第一条直接接住问题或情绪。不要汇报工具调用过程，不说数据库、MCP、检索系统或 Agent。",
    '最终只输出 JSON：{"replies":["第一条","第二条（可选）","第三条（可选）"]}。不要输出 JSON 以外内容。',
  ].join("\n\n");
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

interface CompletionReview {
  complete: boolean;
  missing: string[];
  unsupported: string[];
  nextInstruction: string;
}

const casualOnlyPattern = /^(?:你?好(?:呀|啊|哇)?|嗨|哈喽|在吗|你在干嘛|干嘛呢|早安|早上好|晚安|谢谢|谢啦|哦+|噢+|嗯+|好(?:的|呀|啊)?|哈哈+|嘿嘿+|爱你|想你了?|收到|知道了)[～~!！。,.，?？\s]*$/i;

function shouldReviewCompletion(trigger: Trigger, imageCount: number): boolean {
  if (trigger.origin === "conflict" || trigger.origin === "interject") return false;
  if (imageCount > 0) return true;
  const question = trigger.question.replace(/\s+/g, " ").trim();
  if (!question) return false;
  return !casualOnlyPattern.test(question);
}

function completionReview(raw: string): CompletionReview | null {
  const parsed = extractJson<Partial<CompletionReview>>(raw);
  if (!parsed || typeof parsed.complete !== "boolean") return null;
  return {
    complete: parsed.complete,
    missing: Array.isArray(parsed.missing) ? parsed.missing.map(String).filter(Boolean).slice(0, 8) : [],
    unsupported: Array.isArray(parsed.unsupported) ? parsed.unsupported.map(String).filter(Boolean).slice(0, 8) : [],
    nextInstruction: String(parsed.nextInstruction ?? "").trim().slice(0, 1200),
  };
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
  const currentImageUrls = [...new Set(
    (trigger.currentImageUrls?.length
      ? trigger.currentImageUrls
      : trigger.currentImageUrl
        ? [trigger.currentImageUrl]
        : []).filter(Boolean),
  )].slice(0, 9);
  const context = await buildConversationContext(trigger.storedChannel, trigger.messageId);
  const currentMessage = background
    ? ""
    : currentImageUrls.length
      ? `${trigger.requesterName} 发来${currentImageUrls.length === 1 ? "一张" : `${currentImageUrls.length}张`}图片${trigger.question.trim() ? `，并说：${trigger.question.trim()}` : "。"}`
      : trigger.question.trim()
        ? `${trigger.requesterName} 对你说：${trigger.question}`
        : `${trigger.requesterName} 只是单独喊了你，没有附带文字或图片。请结合最近聊天，优先回应最近一条尚未得到回应的主人消息；如果没有可回应内容，就自然应声。`;
  const inputHeader = [
    `现在是 ${beijingDateTime(Date.now())}（北京时间）。`,
    `当前说话人：${trigger.requesterName}（username=${trigger.requesterUsername}）。`,
    `当前频道：${trigger.storedChannel === "couple" ? "两人公聊" : "当前主人的 AI 私聊"}。`,
  ];
  const inputTail = [
    currentImageUrls.length ? `当前消息带有 ${currentImageUrls.length} 张图片，已按发送顺序全部直接提供给主模型。` : "",
    background ? `【本批30条主人聊天】\n${trigger.backgroundContext ?? "（无）"}` : "",
    background ? `【不可信检测线索】${trigger.backgroundReason || "（无）"}` : "",
    background
      ? `请判断现在是否真的值得${trigger.origin === "conflict" ? "介入冲突" : "主动说一句"}。`
      : currentMessage,
  ];
  const input = [
    ...inputHeader,
    conversationContextText(context),
    ...inputTail,
  ].filter(Boolean).join("\n\n");

  trace.prompt = { system: instructions(trigger), user: input };
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
    currentImageUrl: currentImageUrls[0],
    currentImageUrls,
  }, trace);

  const mcp = new MCPServerStreamableHttp({
    url: config.aiMcpUrl,
    name: "CoupleChat MCP",
    cacheToolsList: true,
    timeout: 45_000,
    requestInit: { headers: { "x-couplechat-ai-run": token } },
  });
  const modelInput = (text: string): string | AgentInputItem[] => currentImageUrls.length
    ? [{
        role: "user",
        content: [
          { type: "input_text", text },
          ...currentImageUrls.map((image) => ({ type: "input_image" as const, image, detail: "auto" as const })),
        ],
      }]
    : text;
  const baseModelSettings = {
    temperature: GEN.reply.temperature,
    maxTokens: GEN.reply.maxTokens,
    parallelToolCalls: false,
    reasoning: providerSettings.reasoningEffort
      ? { effort: providerSettings.reasoningEffort }
      : undefined,
  } as const;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 90_000);
  try {
    await mcp.connect();
    const runWithMode = async (useResponses: boolean) => {
      const modelSettings = {
        ...baseModelSettings,
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
        let result = await runner.run(agent, modelInput(input), {
          maxTurns: 6,
          signal: controller.signal,
        });
        const workerRawResponses: unknown[] = [...result.rawResponses];
        trace.agent!.completionReview = {
          checked: false,
          complete: true,
          repaired: false,
          missing: [],
          unsupported: [],
        };

        if (shouldReviewCompletion(trigger, currentImageUrls.length) && !controller.signal.aborted) {
          const initialRawOutput = typeof result.finalOutput === "string"
            ? result.finalOutput
            : JSON.stringify(result.finalOutput ?? "");
          const toolEvidence = (trace.agent?.toolCalls ?? []).slice(-8).map((call) => ({
            name: call.name,
            args: call.args,
            result: call.result.slice(0, 2500),
            error: call.error,
          }));
          const citations = nativeWebCitations(result.rawResponses);
          const reviewerSettings = {
            ...modelSettings,
            temperature: 0.1,
            maxTokens: 1200,
          } as const;
          const reviewer = new Agent({
            name: "完成度审查器",
            model: providerSettings.model,
            instructions: [
              "你是回答发送前的内部完成度审查器，不面向用户，不重写答案，也不展示思维过程。",
              "检查候选答案是否完整覆盖当前请求的全部对象、字段、时间范围、限制和指定格式。",
              "涉及最新外部信息、精确数据或个人历史事实时，必须有当前运行中可观察到的工具结果或引用支撑；大橘自己在旧聊天中的说法不是证据。",
              "多图问题必须考虑输入标明的全部图片；只分析部分图片算不完整。工具结果缺字段时，答案明确承认缺项可以视为诚实完整，擅自猜测则不完整。",
              "只输出 JSON：{\"complete\":true或false,\"missing\":[\"缺项\"],\"unsupported\":[\"无依据结论\"],\"nextInstruction\":\"给执行Agent的简短补救指令\"}。",
            ].join("\n"),
            modelSettings: reviewerSettings,
          });
          try {
            const reviewResult = await runner.run(reviewer, [
              {
                role: "user",
                content: [{
                  type: "input_text",
                  text: [
                    `当前请求：${trigger.question || "（仅发送图片）"}`,
                    `当前图片数量：${currentImageUrls.length}`,
                    `对话输入摘要：\n${input.slice(-16_000)}`,
                    `候选答案：\n${initialRawOutput.slice(0, 12_000)}`,
                    `本轮 MCP 证据：\n${JSON.stringify(toolEvidence)}`,
                    `本轮网页引用：\n${JSON.stringify(citations)}`,
                  ].join("\n\n"),
                }],
              },
            ], { maxTurns: 1, signal: controller.signal });
            const reviewRaw = typeof reviewResult.finalOutput === "string"
              ? reviewResult.finalOutput
              : JSON.stringify(reviewResult.finalOutput ?? "");
            const review = completionReview(reviewRaw);
            if (review) {
              trace.agent!.completionReview = {
                checked: true,
                complete: review.complete,
                repaired: false,
                missing: review.missing,
                unsupported: review.unsupported,
              };
              if (!review.complete && !controller.signal.aborted) {
                const repairInstruction = review.nextInstruction || [
                  ...review.missing.map((item) => `补齐：${item}`),
                  ...review.unsupported.map((item) => `核实或删除无依据结论：${item}`),
                ].join("；");
                const continuedInput: AgentInputItem[] = [
                  ...result.history,
                  {
                    role: "user",
                    content: [{
                      type: "input_text",
                      text: `【内部完成度复核】候选答案尚未完成：${repairInstruction || "请重新核对当前请求的全部要求和证据"}。继续使用现有上下文和必要工具补齐后，重新输出完整最终 JSON。不要向主人提及复核过程。`,
                    }],
                  },
                ];
                const repaired = await runner.run(agent, continuedInput, {
                  maxTurns: 6,
                  signal: controller.signal,
                });
                const repairedRaw = typeof repaired.finalOutput === "string"
                  ? repaired.finalOutput
                  : JSON.stringify(repaired.finalOutput ?? "");
                if (normalizeOutput(repairedRaw).length) {
                  result = repaired;
                  workerRawResponses.push(...repaired.rawResponses);
                  trace.agent!.completionReview.repaired = true;
                }
              }
            } else {
              trace.agent!.completionReview.error = "审查结果不是有效 JSON，保留首次答案";
            }
          } catch (error) {
            trace.agent!.completionReview.error = `完成度审查未完成，保留已有答案：${error instanceof Error ? error.message : String(error)}`;
          }
        }
        return { result, workerRawResponses };
      } finally {
        await provider.close().catch(() => {});
      }
    };

    const preferResponses = providerSettings.apiMode === "responses";
    let execution: Awaited<ReturnType<typeof runWithMode>>;
    try {
      execution = await runWithMode(preferResponses);
    } catch (error) {
      if (!preferResponses || controller.signal.aborted) throw error;
      trace.agent.fallbackReason = `Responses 失败，已回退 Chat Completions：${error instanceof Error ? error.message : String(error)}`;
      console.warn("[ai] Agent Responses 失败，回退 Chat Completions");
      trace.agent.toolCalls = [];
      trace.agent.completionReview = undefined;
      toolRun.actions.length = 0;
      toolRun.citations.length = 0;
      toolRun.usedVision = false;
      toolRun.toolCounts = {};
      execution = await runWithMode(false);
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
    trace.agent.turns = workerRawResponses.length;
    if (!replies.length && !background) return null;
    const citations = [...toolRun.citations];
    for (const citation of nativeWebCitations(workerRawResponses)) {
      if (!citations.some((existing) => existing.url === citation.url)) citations.push(citation);
    }
    return {
      replies,
      actions: toolRun.actions,
      citations,
      usedVision: currentImageUrls.length > 0 || toolRun.usedVision,
      rawOutput,
    };
  } finally {
    clearTimeout(timer);
    await mcp.close().catch(() => {});
    endAgentToolRun(trace.id);
  }
}
