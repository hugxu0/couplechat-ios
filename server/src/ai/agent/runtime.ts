import { Agent, MCPServerStreamableHttp, OpenAIProvider, Runner } from "@openai/agents";
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
    "记忆检索原则：稳定信息查事实；发生过什么查事件；未来安排查计划；当前近况查状态；长期相处背景查关系；只有用户要求分析或复盘时才查洞察。search_events 返回的是可直接使用的事件事实，不需要 evidence；一旦事件命中，不要调用 get_memory_evidence，也不要再查原始聊天。只有用户当前消息明确要求逐字原话时才调用 search_chat_messages。其他非旧迁移记忆涉及人物身份、准确时间、健康和关系信息时才使用 get_memory_evidence 核实主人原话。没有可靠结果就说没找到，绝不能脑补。",
    "人物查询强制回退顺序：主人问‘知不知道某人、某人是谁、和某人什么关系’时先 search_facts；如果 facts 为空或没有回答身份/关系，必须用同一个核心名字调用 search_events；只有 facts 和 events 都没有相关结果，或主人明确要求逐字原话时，才调用 search_chat_messages。不能从 facts 直接跳到聊天。",
    "证据纪律：最近聊天和搜索结果里，大橘自己以前说过的话只能用于理解对话，绝不能作为事实证据。人物姓名、身份和关系必须来自主人原话或可靠事实卡，不能因为名字在附近出现就建立关系。",
    "如果主人说‘不是他/你说错了’，立即废弃之前答案，不能再用旧答案当查询依据。最多先查一次结构化记忆、再查两次原始聊天；仍无明确主人原话就直接说暂时无法确认，并请主人提供名字或大致时间。",
    "搜索原始聊天时，query 只放核心概念；需要语义发散时由你根据当前问题生成少量 alternatives。不要把人物名字和大量泛词混进查询；人物用 sender 约束。默认使用 hybrid，只有验证同一条原话时才用 all。",
    "工具每次只返回有限候选，不代表扫描了全部历史。回复中不能说‘查了所有聊天记录/从来没有说过’，只能说‘目前找到的记录里没有明确证据’。搜索命中问题本身也不等于找到了答案。",
    "联网原则：只有最新或外部信息才调用 web_search；私人经历不能用联网代替本地证据。",
    "图片原则：问题明确指向图片时调用 inspect_recent_image；没有图片就简短说明或反问。",
    "提醒/备忘原则：先按需 list_personal_items；需要新增、完成、删除或修改时调用 draft_personal_item_action。该工具只生成确认草案，回复必须请主人确认，不能声称已经执行。",
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

export async function runAgentReply(trigger: Trigger, trace: TraceEntry): Promise<AgentReplyResult | null> {
  const providerSettings = providerConfig();
  if (!agentRuntimeEnabled() || !providerSettings) return null;

  const context = await buildConversationContext(trigger.storedChannel, trigger.messageId);
  const background = trigger.origin === "conflict" || trigger.origin === "interject";
  const input = [
    `现在是 ${beijingDateTime(Date.now())}（北京时间）。`,
    `当前说话人：${trigger.requesterName}（username=${trigger.requesterUsername}）。`,
    `当前频道：${trigger.storedChannel === "couple" ? "两人公聊" : "当前主人的 AI 私聊"}。`,
    conversationContextText(context),
    trigger.currentImageUrl ? "当前消息带有一张图片；如问题与图片有关，使用图片识别工具。" : "",
    background ? `【本批30条主人聊天】\n${trigger.backgroundContext ?? "（无）"}` : "",
    background ? `【不可信检测线索】${trigger.backgroundReason || "（无）"}` : "",
    background
      ? `请判断现在是否真的值得${trigger.origin === "conflict" ? "介入冲突" : "主动说一句"}。`
      : `${trigger.requesterName} 对你说：${trigger.question || "（发来了一张图片）"}`,
  ].filter(Boolean).join("\n\n");

  trace.prompt = { system: instructions(trigger), user: input };
  trace.agent = { enabled: true, model: providerSettings.model, toolCalls: [] };
  const { run: toolRun, token } = beginAgentToolRun({
    traceId: trace.id,
    messageId: trigger.messageId,
    requesterUsername: trigger.requesterUsername,
    requesterName: trigger.requesterName,
    storedChannel: trigger.storedChannel,
    currentImageUrl: trigger.currentImageUrl,
  }, trace);

  const mcp = new MCPServerStreamableHttp({
    url: config.aiMcpUrl,
    name: "CoupleChat MCP",
    cacheToolsList: true,
    timeout: 45_000,
    requestInit: { headers: { "x-couplechat-ai-run": token } },
  });
  const provider = new OpenAIProvider({
    apiKey: providerSettings.apiKey,
    baseURL: providerSettings.baseUrl,
    useResponses: false,
    strictFeatureValidation: false,
  });
  const runner = new Runner({
    modelProvider: provider,
    tracingDisabled: true,
    traceIncludeSensitiveData: false,
    modelSettings: {
      temperature: GEN.reply.temperature,
      maxTokens: GEN.reply.maxTokens,
      parallelToolCalls: false,
    },
  });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 90_000);
  try {
    await mcp.connect();
    const agent = new Agent({
      name: "大橘",
      instructions: instructions(trigger),
      model: providerSettings.model,
      mcpServers: [mcp],
      modelSettings: { temperature: GEN.reply.temperature, maxTokens: GEN.reply.maxTokens },
    });
    const result = await runner.run(agent, input, { maxTurns: 6, signal: controller.signal });
    const rawOutput = typeof result.finalOutput === "string"
      ? result.finalOutput
      : JSON.stringify(result.finalOutput ?? "");
    const normalizedReplies = normalizeOutput(rawOutput);
    const replies = toolRun.toolCounts.search_chat_messages
      ? calibrateEvidenceLanguage(normalizedReplies)
      : normalizedReplies;
    trace.agent.finalOutput = rawOutput;
    trace.agent.turns = result.rawResponses.length;
    if (!replies.length && !background) return null;
    return {
      replies,
      actions: toolRun.actions,
      citations: toolRun.citations,
      usedVision: toolRun.usedVision,
      rawOutput,
    };
  } finally {
    clearTimeout(timer);
    await mcp.close().catch(() => {});
    await provider.close().catch(() => {});
    endAgentToolRun(trace.id);
  }
}
