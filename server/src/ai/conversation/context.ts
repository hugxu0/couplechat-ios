import { compactLine, compactLines, recentMessages } from "./log";
import { CONTEXT, GEN } from "../settings";
import { chat } from "../provider";
import { readRuntimeState, writeRuntimeState } from "../runtimeState";

interface StoredContext {
  summary: string;
  upToTs: number;
}

const updating = new Set<string>();

async function readContext(channel: string): Promise<StoredContext> {
  try {
    const raw = await readRuntimeState(`context:${channel}`);
    if (!raw) return { summary: "", upToTs: 0 };
    const parsed = JSON.parse(raw) as Partial<StoredContext>;
    return {
      summary: String(parsed.summary ?? ""),
      upToTs: Number(parsed.upToTs) || 0,
    };
  } catch {
    return { summary: "", upToTs: 0 };
  }
}

export async function buildConversationContext(channel: string, currentMessageId?: string) {
  const [stored, recent] = await Promise.all([
    readContext(channel),
    recentMessages(channel, CONTEXT.recentCount + 1),
  ]);
  const visible = currentMessageId ? recent.filter((message) => message.id !== currentMessageId) : recent;
  return {
    summary: stored.summary.slice(0, CONTEXT.summaryMaxChars),
    recent: visible.slice(-CONTEXT.recentCount),
  };
}

export async function updateConversationContext(channel: string): Promise<void> {
  if (updating.has(channel)) return;
  const rows = await recentMessages(channel, CONTEXT.recentCount + CONTEXT.summaryBacklogMax);
  const outsideWindow = rows.slice(0, Math.max(0, rows.length - CONTEXT.recentCount));
  const stored = await readContext(channel);
  const fresh = outsideWindow.filter((message) => message.kind !== "system" && message.ts > stored.upToTs);
  if (fresh.length < CONTEXT.summaryUpdateEvery) return;

  updating.add(channel);
  try {
    const output = await chat({
      profile: "task",
      system: [
        "你负责压缩一段持续进行的聊天上下文。",
        "保留明确事实、决定、时间地点、未完成事项和仍在进行的话题；完成且不再相关的闲聊可以删除。",
        "只写原文明确表达的内容，不评价、不推测、不补充。输出简短连续文本，不超过 500 字。",
      ].join("\n"),
      user: [
        `【已有摘要】\n${stored.summary || "（空）"}`,
        `【新增聊天】\n${fresh.map((message) => compactLine(message, 160)).filter(Boolean).join("\n")}`,
      ].join("\n\n"),
      gen: GEN.contextSummary,
    });
    const summary = output?.trim();
    if (!summary) return;
    await writeRuntimeState(`context:${channel}`, JSON.stringify({
      summary: summary.slice(0, 1200),
      upToTs: fresh[fresh.length - 1].ts,
    }));
  } finally {
    updating.delete(channel);
  }
}

export function conversationContextText(context: Awaited<ReturnType<typeof buildConversationContext>>): string {
  return [
    context.summary ? `【较早对话摘要】\n${context.summary}` : "",
    context.recent.length ? `【最近聊天】\n${compactLines(context.recent)}` : "【最近聊天】暂无",
  ].filter(Boolean).join("\n\n");
}
