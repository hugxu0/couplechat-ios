// 大橘日记：把上一作息日的完整 couple 公聊交给大橘，一次写成大橘自己的日记。
// 不读取任一账号 AI 私聊；不使用日总览、选材器或二次改写。

import { nanoid } from "nanoid";
import { all, get, run } from "../../db";
import { conversationMessagesInRange, compactLine } from "../conversation/log";
import { chat, extractJson } from "../provider";
import { GEN } from "../settings";
import { addDays, cycleBounds, cycleDate } from "../time";

const COUPLE_ID = "cpl_legacy_xusi";
const CHANNEL = "couple";
const DIARY_MAX_MESSAGES = 3000;
const DIARY_MAX_CHARS = 180_000;

export interface DailyDiary {
  id: string;
  coupleId: string;
  dayKey: string;
  title: string;
  body: string;
  source: string;
  createdAt: number;
  updatedAt: number;
}

/** 仅为本地兜底 smoke 保留的旧摘要形状；正式生成不再读取它。 */
export interface DayDigestLike {
  dayKey?: string;
  topics?: Array<{ title?: string; points?: string[] }>;
  moodLine?: string;
}

function mapRow(row: {
  id: string;
  couple_id: string;
  day_key: string;
  title: string;
  body: string;
  source: string;
  created_at: number;
  updated_at: number;
}): DailyDiary {
  return {
    id: row.id,
    coupleId: row.couple_id,
    dayKey: row.day_key,
    title: row.title,
    body: row.body,
    source: row.source,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function truncateCharacters(value: string, limit: number): string {
  return Array.from(value).slice(0, limit).join("");
}

function cleanLine(value: unknown, limit = 180): string {
  return truncateCharacters(String(value ?? "").replace(/\s+/g, " ").trim(), limit);
}

function withoutTerminalPunctuation(value: string): string {
  return value.replace(/[。！？!?；;，,\s]+$/u, "");
}

function splitLongParagraph(paragraph: string): string[] {
  const sentences = paragraph.match(/[^。！？!?]+[。！？!?]?/gu)?.map((item) => item.trim()).filter(Boolean) ?? [];
  if (sentences.length < 3) return [paragraph];
  const desiredChunks = Math.min(3, Math.max(2, Math.ceil(paragraph.length / 100)));
  const targetLength = Math.ceil(paragraph.length / desiredChunks);
  const chunks: string[] = [];
  let current = "";
  for (const [index, sentence] of sentences.entries()) {
    current += sentence;
    if (current.length >= targetLength && index < sentences.length - 1 && chunks.length < desiredChunks - 1) {
      chunks.push(current.trim());
      current = "";
    }
  }
  if (current.trim()) chunks.push(current.trim());
  return chunks;
}

export function normalizeDiaryBody(value: string): string {
  const paragraphs = value
    .replace(/\r\n?/g, "\n")
    .split(/\n+/)
    .map((paragraph) => paragraph.replace(/[ \t]+/g, " ").trim())
    .filter(Boolean);
  const readable = paragraphs.length === 1 ? splitLongParagraph(paragraphs[0]) : paragraphs;
  return truncateCharacters(readable.slice(0, 3).join("\n\n"), 520).trim();
}

function normalizeDiaryTitle(value: string): string {
  return truncateCharacters(
    value.replace(/[#*_`"“”‘’]+/g, "").replace(/\s+/g, " ").trim(),
    18,
  );
}

/** 只有格式和长度保护，不再用词表替模型写作。 */
export function isUsableDiaryBody(value: string): boolean {
  if (value.length < 70 || value.length > 520) return false;
  if (/(^|\n)\s*(#{1,6}\s|[-*+]\s|\d+[.)]\s)/m.test(value)) return false;
  return !/(根据(?:给定)?材料|输入的JSON|作为AI|系统提示)/u.test(value);
}

/** 模型不可用时的最小兜底，也保持“大橘在写自己的日记”的视角。 */
export function buildDiaryFallback(digest: DayDigestLike): { title: string; body: string } {
  const topic = cleanLine(digest.topics?.[0]?.title, 32);
  const point = cleanLine(digest.topics?.[0]?.points?.[0], 100);
  const title = normalizeDiaryTitle(topic ? `我记住的${withoutTerminalPunctuation(topic)}` : "大橘记下这一页");
  const first = topic
    ? `我趴在聊天旁边，记住了你们说起“${withoutTerminalPunctuation(topic)}”的那一会儿。${point ? `${withoutTerminalPunctuation(point)}。` : ""}`
    : `我趴在聊天旁边，看着这一天的声音慢慢亮起来。${digest.moodLine ? `${withoutTerminalPunctuation(cleanLine(digest.moodLine, 80))}。` : ""}`;
  return {
    title,
    body: normalizeDiaryBody(`${first}\n\n我没有急着插话，只把这一小段安静收进自己的记忆里。`),
  };
}

async function loadFullDiaryConversation(dayKey: string): Promise<string[]> {
  const { start, end } = cycleBounds(dayKey);
  const messages = await conversationMessagesInRange(CHANNEL, start, end, DIARY_MAX_MESSAGES);
  const lines: string[] = [];
  let characters = 0;
  for (const message of messages) {
    // 日记输入保留每条消息的完整正文；只在整日窗口超过安全上限时截断尾部。
    const line = compactLine(message, DIARY_MAX_CHARS);
    if (!line) continue;
    if (characters + line.length > DIARY_MAX_CHARS) break;
    lines.push(line);
    characters += line.length + 1;
  }
  return lines;
}

function fallbackFromConversation(lines: string[]): { title: string; body: string } {
  const first = lines[0]?.replace(/^\d{2}:\d{2}\s+[^:：]{1,24}[:：]\s*/u, "").trim();
  const detail = first ? `我记得最先落下来的那句话：“${cleanLine(first, 100)}”。` : "我趴在旁边，看着这一天的聊天慢慢有了形状。";
  return {
    title: "我记住的这一页",
    body: normalizeDiaryBody(`${detail}\n\n我没有急着插话，只把后来那些声音和自己的小心思一起收好。`),
  };
}

export async function getDiary(dayKey: string): Promise<DailyDiary | null> {
  const row = await get<{
    id: string;
    couple_id: string;
    day_key: string;
    title: string;
    body: string;
    source: string;
    created_at: number;
    updated_at: number;
  }>(
    `SELECT * FROM ai_daily_diaries WHERE couple_id = ? AND day_key = ?`,
    [COUPLE_ID, dayKey],
  );
  return row ? mapRow(row) : null;
}

export async function listDiaries(limit = 30): Promise<DailyDiary[]> {
  const rows = await all<{
    id: string;
    couple_id: string;
    day_key: string;
    title: string;
    body: string;
    source: string;
    created_at: number;
    updated_at: number;
  }>(
    `SELECT * FROM ai_daily_diaries WHERE couple_id = ? ORDER BY day_key DESC LIMIT ?`,
    [COUPLE_ID, Math.max(1, Math.min(90, limit))],
  );
  return rows.map(mapRow);
}

/** 为指定作息日生成或返回已有日记。正式生成只使用完整 couple 公聊。 */
export async function ensureDiaryForDay(dayKey: string, options?: { force?: boolean }): Promise<DailyDiary | null> {
  if (!options?.force) {
    const existing = await getDiary(dayKey);
    if (existing) return existing;
  }

  const lines = await loadFullDiaryConversation(dayKey);
  if (!lines.length) {
    console.log(`[diary] skip empty day=${dayKey}`);
    return null;
  }

  const fallback = fallbackFromConversation(lines);
  let title = fallback.title;
  let body = fallback.body;
  try {
    const raw = await chat({
      profile: "task",
      scope: "diary",
      system: [
        "你是大橘。请把下面上一作息日的完整情侣公聊，写成一篇真正属于大橘自己的日记。",
        "这是大橘的日记，不是主人的聊天总结。大橘要写自己的观察、感受、联想和小心思：像一只一直趴在旁边、记得声音和气氛的猫。",
        "请通读全部聊天，再自己挑最让大橘记住的两三幕来写，不要按消息逐条复述，也不要把所有事情列出来。可以写大橘觉得安心、好奇、担心或想插话，但不能把主人没说出口的心理当成事实，不能替他们做判断或给建议。",
        "正文要有具体画面和时间推进，最后停在大橘自己的一个念头或当晚的一幕。不要出现时间戳、说话人前缀、JSON、摘要标签、心理咨询话术或列表。",
        "标题 6～16 个中文字符；正文 120～300 个中文字符，2～3 个自然段。只输出 JSON：{\"title\":\"...\",\"body\":\"段落1\\n\\n段落2\"}。",
      ].join("\n"),
      user: `上一作息日（北京时间 06:00 到次日 06:00）的完整公聊记录，按时间顺序：\n${lines.join("\n")}`,
      gen: GEN.diary,
    });
    const parsed = extractJson<{ title?: string; body?: string }>(raw);
    const candidateTitle = normalizeDiaryTitle(parsed?.title ?? "");
    const candidateBody = normalizeDiaryBody(parsed?.body ?? "");
    if (candidateTitle.length >= 4) title = candidateTitle;
    if (isUsableDiaryBody(candidateBody)) body = candidateBody;
  } catch (error) {
    console.warn("[diary] 生成失败，使用完整聊天兜底:", error instanceof Error ? error.message : error);
  }

  const now = Date.now();
  const id = `diary_${nanoid(12)}`;
  await run(
    `INSERT INTO ai_daily_diaries (id, couple_id, day_key, title, body, source, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, 'auto', ?, ?)
     ON CONFLICT (couple_id, day_key) DO UPDATE SET
       title = EXCLUDED.title,
       body = EXCLUDED.body,
       source = EXCLUDED.source,
       updated_at = EXCLUDED.updated_at`,
    [id, COUPLE_ID, dayKey, title, body, now, now],
  );
  return getDiary(dayKey);
}

/** 确保「上一作息日」日记（北京时间 06:00 切日）。 */
export async function ensureYesterdayDiary(
  now = Date.now(),
  options?: { force?: boolean },
): Promise<DailyDiary | null> {
  return ensureDiaryForDay(addDays(cycleDate(now), -1), options);
}
