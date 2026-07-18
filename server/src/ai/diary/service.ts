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

function truncateDiaryBody(value: string, limit: number): string {
  if (Array.from(value).length <= limit) return value;
  const clipped = Array.from(value).slice(0, limit).join("");
  const boundary = [...clipped.matchAll(/[。！？!?]/gu)].at(-1)?.index;
  if (boundary !== undefined && boundary >= Math.floor(limit * 0.72)) {
    return clipped.slice(0, boundary + 1).trim();
  }
  return clipped.trim();
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
  const desiredChunks = Math.min(6, Math.max(3, Math.ceil(paragraph.length / 150)));
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
  return truncateDiaryBody(readable.slice(0, 6).join("\n\n"), 640).trim();
}

function normalizeDiaryTitle(value: string): string {
  return truncateCharacters(
    value.replace(/[#*_`"“”‘’]+/g, "").replace(/\s+/g, " ").trim(),
    18,
  );
}

/** 只有格式和长度保护，不再用词表替模型写作。 */
export function isUsableDiaryBody(value: string): boolean {
  if (value.length < 180 || value.length > 640) return false;
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
        "这是大橘的日记，不是主人的聊天总结，也不是把聊天换成第一人称重新讲一遍。大橘是一只有性格、有偏爱、会走神也会琢磨事情的猫，要写自己的观察、感受、联想和没想明白的小心思。",
        "通读全部聊天后，先找到这一天最让大橘放不下的一条暗线、一个变化或一个疑问，只围绕它往深处写。具体聊天只是让这条思考长出来的土壤，不是待办清单；不必覆盖全天，不要按“先聊了、后来又聊了、最后聊了”串联事项。",
        "至少写进一个只有当天聊天才会有的具体细节，再写大橘当时的反应、它由此想到什么、还有什么没有想通。大橘可以安心、好奇、担心、吃醋、犯困或想插话；对主人内心的理解只能写成大橘自己的猜测，不能冒充事实，不能替主人判断或给建议。",
        "文字要像大橘在夜里写下的一页私密手记：克制、柔软、有一点诗意。可以借窗、灯、夜色、风声、影子和猫的身体感受营造意境，但必须写成大橘的联想或感受，不能把聊天之外的环境当成事实；不要堆砌华丽形容词或写成鸡汤。让一个具体声音、动作或物件慢慢牵出大橘的联想，结尾停在一个具体动作、声音、念头或仍悬着的问题，不总结道理。不要出现时间戳、说话人前缀、摘要标签、心理咨询话术或列表。",
        "标题 6～16 个中文字符，要像诗句或短篇标题，有具体意象和余韵，不要直接概括冲突或下结论，不要使用“被……吵醒”“我记住的……”等说明型模板。正文 420～560 个中文字符，4～5 个自然段。只输出 JSON：{\"title\":\"...\",\"body\":\"段落1\\n\\n段落2\\n\\n段落3\"}。",
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
