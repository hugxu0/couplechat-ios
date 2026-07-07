// 应答引擎：一轮 LLM 调用直出 1~3 条回复，像真人发微信一样逐条发出。
//
// 上下文分两层组织（这是缓存友好的关键设计）：
//   system  = 人设 + 人物卡 + 关系卡 + 短期记忆 + 今日心情 + 输出格式
//             ——一天内基本不变，Claude 系模型能吃到提示词缓存（约 1/10 计费）。
//   user    = 对话前情摘要 + 最近聊天 + 静默召回的记忆 + 当前这条消息
//             ——每次都变的部分。
//
// 对比旧版：plan（意图规划）+ retrievalQuery（检索词生成）+ ask（正式回复）三轮
// 合并成一轮；检索词直接用「当前问题 + 最近几条用户消息」拼接。

import { accounts, getDoc } from "./memoryStore";
import { compactLine, recentMessages, type LogMessage } from "./chatLog";
import { chat, extractJson, extractReplyText } from "./provider";
import { recallSafe } from "./recall";
import { summaryText } from "./sessionSummary";
import { ensureDailyMood } from "./nightly";
import { personaCore, BOT_NAME } from "./persona";
import { CONTEXT, GEN, MEMORY, PACE } from "./params";
import { beijingDateTime, cycleDate } from "./time";

export interface ReplySink {
  // 发一条大橘消息进频道（含入库+广播+推送），返回后继续下一条。
  emit(storedChannel: string, text: string, isFirst: boolean): Promise<void>;
  // 「正在输入」气泡开关。
  typing(storedChannel: string, value: boolean): void;
}

export interface Trigger {
  storedChannel: string;
  question: string;
  requesterName: string;
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ─── 上下文组装 ──────────────────────────────────────────────────────────

function profileCardsText(): string {
  const parts: string[] = [];
  for (const a of accounts()) {
    const text = getDoc(`profile:${a.username}`);
    if (text) parts.push(`## ${a.name}\n${text}`);
  }
  const rel = getDoc("relationship");
  if (rel) parts.push(`## 两人关系\n${rel}`);
  return parts.join("\n\n");
}

function buildSystem(isPrivate: boolean, mood: string): string {
  const names = accounts().map((a) => a.name);
  const cards = profileCardsText();
  const shortTerm = getDoc("short-term").slice(0, MEMORY.shortTermMax);
  return [
    personaCore(names),
    isPrivate
      ? "这里是你和其中一位主人的私聊小窗：只有你们两个，说话可以更贴近这一位主人；私聊内容不要透给另一位主人。"
      : "这里是两位主人共同的聊天频道，他们 @你 时你才说话；你说的话两个人都看得到。",
    cards ? `【你对两位主人的了解（人物卡）】\n${cards}` : "",
    shortTerm ? `【短期记忆（最近一周发生的事）】\n${shortTerm}` : "",
    mood ? `【你今天的心情底色】${mood}` : "",
    "【回复格式】",
    "像人发微信一样说话：一次 1~3 条短消息，每条一句到三句话；不要一大段小作文。",
    "不要用「亲爱的用户」式客服腔；下面【相关记忆】【前情摘要】只在真相关时自然带出，不要机械复述。",
    '只输出 JSON：{"replies":["第一条","第二条（可选）","第三条（可选）"]}',
    "不要输出 JSON 以外的任何内容。",
  ].filter(Boolean).join("\n\n");
}

function buildUser(trigger: Trigger, recent: LogMessage[], factsContext: string, episodesContext: string): string {
  const lines = recent
    .filter((m) => m.kind !== "system")
    .map((m) => compactLine(m))
    .filter(Boolean);
  const n = CONTEXT.immediateCount;
  const earlier = lines.slice(0, Math.max(0, lines.length - n)).join("\n");
  const immediate = lines.slice(-n).join("\n") || "暂无最近聊天";
  const summary = summaryText(trigger.storedChannel);
  return [
    `现在是 ${beijingDateTime(Date.now())}（北京时间）。`,
    summary ? `【前情摘要（更早对话的脉络）】\n${summary}` : "",
    earlier ? `【更早背景】\n${earlier}` : "",
    `【紧邻上文（重点看这里）】\n${immediate}`,
    factsContext ? `【相关记忆（长期事实）】\n${factsContext}` : "",
    episodesContext ? `【相关记忆（过往事件）】\n${episodesContext}` : "",
    `${trigger.requesterName} 对你说：${trigger.question || "（没有正文，可能只是唤了你一声）"}`,
    `请以${BOT_NAME}的身份回复。`,
  ].filter(Boolean).join("\n\n");
}

// 检索查询词：当前问题 + 最近几条用户消息原文拼接。
function retrievalQuery(trigger: Trigger, recent: LogMessage[]): string {
  const recentUser = recent
    .filter((m) => m.kind === "user" && m.type === "text" && m.text.trim())
    .slice(-CONTEXT.retrievalRecentUserLines)
    .map((m) => m.text.slice(0, 80));
  return [trigger.question, ...recentUser].join(" ").slice(0, 400);
}

function normalizeReplies(out: string | null): string[] {
  const parsed = extractJson<{ replies?: unknown; reply?: unknown }>(out);
  if (parsed && Array.isArray(parsed.replies)) {
    const replies = parsed.replies.map((r) => String(r ?? "").trim()).filter(Boolean).slice(0, 3);
    if (replies.length) return replies;
  }
  if (parsed && typeof parsed.reply === "string" && parsed.reply.trim()) {
    return [parsed.reply.trim()];
  }
  const fallback = extractReplyText(out);
  return fallback ? [fallback.trim()] : [];
}

// ─── 应答 ────────────────────────────────────────────────────────────────

async function respond(trigger: Trigger, sink: ReplySink): Promise<void> {
  const isPrivate = trigger.storedChannel.startsWith("ai:");
  sink.typing(trigger.storedChannel, true);
  try {
    const recent = recentMessages(trigger.storedChannel, CONTEXT.recentCount);
    const [recalled, mood] = await Promise.all([
      recallSafe(retrievalQuery(trigger, recent), trigger.storedChannel),
      ensureDailyMood().catch(() => ""),
    ]);

    let out = await chat({
      profile: "chat",
      system: buildSystem(isPrivate, mood),
      user: buildUser(trigger, recent, recalled.factsContext, recalled.episodesContext),
      gen: GEN.reply,
    });
    let replies = normalizeReplies(out);
    if (!replies.length) {
      // 上游瞬时抖动（超时/限流）先原样重试一次；仍失败发固定兜底，绝不已读不回。
      out = await chat({
        profile: "chat",
        system: buildSystem(isPrivate, mood),
        user: buildUser(trigger, recent, recalled.factsContext, recalled.episodesContext),
        gen: GEN.reply,
      });
      replies = normalizeReplies(out);
    }
    if (!replies.length) {
      replies = ["呜…我刚脑子卡了一下喵，没接住这句。再说一次好不好？"];
    }

    for (let i = 0; i < replies.length; i += 1) {
      if (i > 0) await sleep(PACE.replyGapMinMs + Math.floor(Math.random() * PACE.replyGapJitterMs));
      await sink.emit(trigger.storedChannel, replies[i], i === 0);
    }
  } finally {
    sink.typing(trigger.storedChannel, false);
  }
}

// ─── 每频道串行队列 ──────────────────────────────────────────────────────
// 连环 @ 时不并发（并发容易触发上游限流），串行逐条回答；
// 积压超过上限直接丢弃新触发（兜底回复已经给了反馈，不用轰炸）。

interface Queue {
  chain: Promise<void>;
  pending: number;
}

const queues = new Map<string, Queue>();

function respondWithTimeout(trigger: Trigger, sink: ReplySink): Promise<void> {
  let timer: NodeJS.Timeout | null = null;
  return Promise.race([
    respond(trigger, sink),
    new Promise<void>((resolve) => {
      timer = setTimeout(() => {
        console.warn(`[ai] 应答超时，释放频道队列: ${trigger.storedChannel}`);
        sink.typing(trigger.storedChannel, false);
        resolve();
      }, PACE.respondTimeoutMs);
    }),
  ]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

export function queueRespond(trigger: Trigger, sink: ReplySink): void {
  const q = queues.get(trigger.storedChannel) ?? { chain: Promise.resolve(), pending: 0 };
  if (q.pending >= PACE.queuePendingMax) return;
  q.pending += 1;
  q.chain = q.chain
    .then(() => respondWithTimeout(trigger, sink))
    .catch((error) => console.warn("[ai] 应答失败:", error instanceof Error ? error.message : error))
    .finally(() => {
      q.pending -= 1;
    });
  queues.set(trigger.storedChannel, q);
}
