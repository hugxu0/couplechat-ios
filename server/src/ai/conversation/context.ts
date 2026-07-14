import { compactLine, compactLines, recentConversationMessages, type LogMessage } from "./log";
import { CONTEXT, GEN } from "../settings";
import { chat } from "../provider";
import { readRuntimeState, writeRuntimeState } from "../runtimeState";

interface StoredContext {
  summary: string;
  upToTs: number;
  upToId: string;
  strategy: "private-rolling-v1" | "public-ai-session-v1" | "";
}

export const CONVERSATION_FOCUS_MESSAGES = CONTEXT.recentFocusCount;
export const CONVERSATION_MAX_MESSAGES = CONTEXT.recentMaxCount;

const updateChains = new Map<string, Promise<void>>();

async function readContext(channel: string): Promise<StoredContext> {
  const expectedStrategy = channel.startsWith("ai:") ? "private-rolling-v1" : "public-ai-session-v1";
  try {
    const raw = await readRuntimeState(`context:${channel}`);
    if (!raw) return { summary: "", upToTs: 0, upToId: "", strategy: "" };
    const parsed = JSON.parse(raw) as Partial<StoredContext>;
    if (parsed.strategy !== expectedStrategy) {
      return { summary: "", upToTs: 0, upToId: "", strategy: "" };
    }
    return {
      summary: String(parsed.summary ?? ""),
      upToTs: Number(parsed.upToTs) || 0,
      upToId: String(parsed.upToId ?? ""),
      strategy: expectedStrategy,
    };
  } catch {
    return { summary: "", upToTs: 0, upToId: "", strategy: "" };
  }
}

function isAfterSummary(message: LogMessage, stored: Pick<StoredContext, "upToTs" | "upToId">): boolean {
  return message.ts > stored.upToTs || (message.ts === stored.upToTs && message.id > stored.upToId);
}

export function selectConversationMessages(
  messages: LogMessage[],
  summaryCursor: { upToTs: number; upToId: string } = { upToTs: 0, upToId: "" },
  currentMessageId?: string,
  privateChannel: boolean = false,
): LogMessage[] {
  const eligible = messages.filter((message) => message.id !== currentMessageId && message.kind !== "system");
  const visible = privateChannel
    ? eligible.filter((message) => isAfterSummary(message, summaryCursor))
    : eligible;
  return visible.slice(-CONVERSATION_MAX_MESSAGES);
}

export function splitConversationMessages(messages: LogMessage[]) {
  return {
    supplemental: messages.slice(0, Math.max(0, messages.length - CONVERSATION_FOCUS_MESSAGES)),
    focus: messages.slice(-CONVERSATION_FOCUS_MESSAGES),
  };
}

export function messagesReadyForRollingSummary(
  messages: LogMessage[],
  summaryCursor: { upToTs: number; upToId: string },
): LogMessage[] {
  const fresh = messages.filter((message) => message.kind !== "system" && isAfterSummary(message, summaryCursor));
  if (fresh.length < CONTEXT.summaryTriggerCount) return [];
  return fresh.slice(0, -CONVERSATION_FOCUS_MESSAGES);
}

export async function buildConversationContext(channel: string, currentMessageId?: string) {
  const privateChannel = channel.startsWith("ai:");
  const [stored, recent] = await Promise.all([
    readContext(channel),
    recentConversationMessages(channel, CONVERSATION_MAX_MESSAGES, currentMessageId),
  ]);
  const visible = selectConversationMessages(recent, stored, currentMessageId, privateChannel);
  const { supplemental, focus } = splitConversationMessages(visible);
  const publicSummaryAlreadyVisible = !privateChannel && Boolean(
    stored.upToId && visible.some((message) => message.id === stored.upToId),
  );
  return {
    summary: publicSummaryAlreadyVisible ? "" : stored.summary.slice(0, CONTEXT.summaryMaxChars),
    supplemental,
    focus,
    recent: visible,
    turnCount: visible.filter((message) => message.sender === "ai").length,
  };
}

async function generateRollingSummary(
  stored: StoredContext,
  sections: string[],
  mode: "private" | "public",
): Promise<string> {
  const modeRule = mode === "public"
    ? "这份摘要只记录主人和大橘直接发生的会话、结论与未完话题；回答前的普通公聊只用于理解本次提问，不能大段收进摘要。"
    : "这份摘要记录主人和大橘私聊中已经滚出原文窗口的内容，方便后续继续聊天。";
  return (await chat({
    profile: "task",
    system: [
      "你负责维护一份持续更新、可供下一轮聊天直接使用的详细滚动摘要。",
      modeRule,
      "优先保留：谁说了什么、明确时间地点、人物与关系、决定与理由、承诺和未完成事项、情绪与态度、仍在延续的话题、后续可能用‘这个/那个/他’指代的具体对象。重要否定和纠正不能丢失。",
      "合并已有摘要与本次新增内容；新信息与旧信息冲突时保留最新明确说法，并删除已被推翻或已完成且不再相关的内容。普通寒暄和重复表达可以省略。",
      "只记录原文明确表达的内容，不评价、不推测、不补充。可使用简短分段或项目符号，控制在 1200 个中文字符以内。",
    ].join("\n"),
    user: [
      `【已有摘要】\n${stored.summary || "（空）"}`,
      ...sections,
    ].join("\n\n"),
    gen: GEN.contextSummary,
  }))?.trim() ?? "";
}

async function updatePrivateRollingSummary(channel: string): Promise<void> {
  const stored = await readContext(channel);
  const rows = await recentConversationMessages(channel, CONTEXT.summaryTriggerCount);
  const compressible = messagesReadyForRollingSummary(rows, stored);
  if (!compressible.length) return;
  const summary = await generateRollingSummary(stored, [
    `【滚出窗口的私聊原文】\n${compressible.map((message) => compactLine(message, 180)).filter(Boolean).join("\n")}`,
  ], "private");
  if (!summary) return;
  const boundary = compressible.at(-1)!;
  await writeRuntimeState(`context:${channel}`, JSON.stringify({
    summary: summary.slice(0, CONTEXT.summaryMaxChars),
    upToTs: boundary.ts,
    upToId: boundary.id,
    strategy: "private-rolling-v1",
  }));
}

async function updatePublicAiSessionSummary(channel: string, triggerMessageId?: string): Promise<void> {
  if (!triggerMessageId) return;
  const stored = await readContext(channel);
  const rows = await recentConversationMessages(channel, CONVERSATION_MAX_MESSAGES + CONVERSATION_FOCUS_MESSAGES);
  const triggerIndex = rows.findIndex((message) => message.id === triggerMessageId);
  if (triggerIndex < 0) return;
  const before = rows.slice(Math.max(0, triggerIndex - CONVERSATION_FOCUS_MESSAGES), triggerIndex);
  const exchange = rows.slice(triggerIndex);
  const boundary = [...exchange].reverse().find((message) => message.sender === "ai");
  if (!boundary) return;
  const summary = await generateRollingSummary(stored, [
    before.length ? `【回答前的普通公聊背景（仅辅助理解，不要大段收入摘要）】\n${compactLines(before)}` : "",
    `【本次主人和大橘的会话】\n${compactLines(exchange)}`,
  ].filter(Boolean), "public");
  if (!summary) return;
  await writeRuntimeState(`context:${channel}`, JSON.stringify({
    summary: summary.slice(0, CONTEXT.summaryMaxChars),
    upToTs: boundary.ts,
    upToId: boundary.id,
    strategy: "public-ai-session-v1",
  }));
}

async function performContextUpdate(channel: string, triggerMessageId?: string): Promise<void> {
  if (channel.startsWith("ai:")) await updatePrivateRollingSummary(channel);
  else await updatePublicAiSessionSummary(channel, triggerMessageId);
}

export function updateConversationContext(channel: string, triggerMessageId?: string): Promise<void> {
  const previous = updateChains.get(channel) ?? Promise.resolve();
  const next = previous.catch(() => undefined).then(() => performContextUpdate(channel, triggerMessageId));
  updateChains.set(channel, next);
  return next.finally(() => {
    if (updateChains.get(channel) === next) updateChains.delete(channel);
  });
}

export function conversationContextText(context: Awaited<ReturnType<typeof buildConversationContext>>): string {
  return [
    context.summary ? `【跨会话滚动摘要】\n${context.summary}` : "",
    context.supplemental.length
      ? `【辅助背景：较早原文，优先级较低；只在重点上下文不足时参考】\n${compactLines(context.supplemental)}`
      : "",
    context.focus.length
      ? `【重点上下文：最近 8 条原文，优先用于理解当前话题、语气和指代】\n${compactLines(context.focus)}`
      : "【重点上下文】暂无",
  ].filter(Boolean).join("\n\n");
}
