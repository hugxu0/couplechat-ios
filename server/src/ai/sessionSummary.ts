// 会话滚动摘要：把滑出「最近聊天窗口」的旧消息压成一段持续更新的«对话前情»。
// 解决「聊得久了忘掉窗口外内容」：窗口外的消息既不在最近聊天里、也还没进当晚的
// 事件卡索引，没有这段摘要大橘就会失忆。收到真人消息后后台更新，应答时读缓存零开销。

import { getDoc, setDoc } from "./memoryStore";
import { recentMessages, compactLine } from "./chatLog";
import { chat } from "./provider";
import { CONTEXT, GEN } from "./params";

interface Stored {
  text: string;
  upToTs: number;
}

function read(storedChannel: string): Stored {
  try {
    const raw = getDoc(`session-summary:${storedChannel}`);
    if (!raw) return { text: "", upToTs: 0 };
    const parsed = JSON.parse(raw) as Partial<Stored>;
    return { text: String(parsed.text ?? ""), upToTs: Number(parsed.upToTs) || 0 };
  } catch {
    return { text: "", upToTs: 0 };
  }
}

export function summaryText(storedChannel: string): string {
  return read(storedChannel).text.slice(0, CONTEXT.sessionSummaryMaxChars);
}

const SYSTEM = [
  "你是聊天记录压缩器，为聊天助手维护一段「对话前情摘要」——它会作为上下文，帮助助手记住已经滑出最近聊天窗口的内容。",
  "输入是【旧摘要】（可能为空）和【新增聊天】，把两者合并成一段新的摘要。要求：",
  "1. 按时间先后组织；越早的内容越简略，已经聊完、明显不再重要的旧话题可以直接删掉。",
  "2. 必须保留：双方作出的决定或约定、明确的事实信息（时间/地点/数字/名字/事项）、还没解决的问题、正在进行的话题脉络。",
  "3. 只写聊天里明确出现的内容，不要评价、不要推测、不要脑补细节。",
  "4. 直接输出摘要正文（简体中文，可分几个短段），不要标题、不要列表、不要 markdown，全文不超过 500 字。",
].join("\n");

const updating = new Set<string>();

// 收到真人消息后调用（fire-and-forget）：窗口外新积累的消息够多时合并重写。
export async function maybeUpdate(storedChannel: string): Promise<void> {
  if (updating.has(storedChannel)) return;
  const window = CONTEXT.recentCount;
  const rows = recentMessages(storedChannel, window + CONTEXT.sessionSummaryBacklogMax);
  const outside = rows.slice(0, Math.max(0, rows.length - window)).filter((m) => m.kind !== "system");
  const prev = read(storedChannel);
  const fresh = outside.filter((m) => m.ts > prev.upToTs);
  if (fresh.length < CONTEXT.sessionSummaryUpdateEvery) return;

  const lines = fresh.map((m) => compactLine(m, 140)).filter(Boolean).join("\n");
  if (!lines) return;

  updating.add(storedChannel);
  try {
    const out = await chat({
      profile: "task",
      system: SYSTEM,
      user: `【旧摘要】\n${prev.text || "（空）"}\n\n【新增聊天】\n${lines}`,
      gen: GEN.sessionSummary,
    });
    const text = out?.trim();
    if (text) {
      setDoc(
        `session-summary:${storedChannel}`,
        JSON.stringify({ text: text.slice(0, 1200), upToTs: fresh[fresh.length - 1].ts }),
      );
    }
  } finally {
    updating.delete(storedChannel);
  }
}
