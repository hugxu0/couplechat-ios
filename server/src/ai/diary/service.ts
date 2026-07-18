// 大橘日记：只读 couple 公聊日总览/归档，生成上一作息日的固定短日记。
// 不读取任一账号 AI 私聊。

import { nanoid } from "nanoid";
import { all, get, run } from "../../db";
import { chat, extractJson } from "../provider";
import { GEN } from "../settings";
import { readRuntimeState } from "../runtimeState";
import { addDays, cycleDate } from "../time";

const COUPLE_ID = "cpl_legacy_xusi";
const CHANNEL = "couple";
const DAY_ARCHIVE_PREFIX = "context:v2:day:";
const STATE_KEY = "context:v2:couple";

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

export interface DayDigestLike {
  dayKey?: string;
  topics?: Array<{ title?: string; status?: string; points?: string[] }>;
  decisions?: string[];
  openLoops?: string[];
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

async function loadDigestForDay(dayKey: string): Promise<DayDigestLike | null> {
  const archived = await readRuntimeState(`${DAY_ARCHIVE_PREFIX}${CHANNEL}:${dayKey}`);
  if (archived) {
    try {
      return JSON.parse(archived) as DayDigestLike;
    } catch {
      // fall through
    }
  }
  // 若目标日仍是「今天」的运行态 dayKey，可读当前 state。
  const live = await readRuntimeState(STATE_KEY);
  if (live) {
    try {
      const parsed = JSON.parse(live) as { dayKey?: string; dayDigest?: DayDigestLike };
      if (parsed.dayKey === dayKey && parsed.dayDigest) return parsed.dayDigest;
    } catch {
      // ignore
    }
  }
  return null;
}

function digestHasSignal(digest: DayDigestLike | null): boolean {
  if (!digest) return false;
  return Boolean(
    (digest.topics?.length ?? 0) ||
      (digest.decisions?.length ?? 0) ||
      (digest.openLoops?.length ?? 0) ||
      (digest.moodLine ?? "").trim(),
  );
}

function truncateCharacters(value: string, limit: number): string {
  return Array.from(value).slice(0, limit).join("");
}

function cleanLine(value: unknown, limit = 160): string {
  return truncateCharacters(String(value ?? "").replace(/\s+/g, " ").trim(), limit);
}

function withoutTerminalPunctuation(value: string): string {
  return value.replace(/[。！？!?；;，,\s]+$/u, "");
}

function diaryMaterial(digest: DayDigestLike) {
  return {
    moodLine: cleanLine(digest.moodLine, 120),
    topics: (digest.topics ?? []).slice(0, 10).map((topic) => ({
      title: cleanLine(topic.title, 40),
      status: topic.status === "done" || topic.status === "dropped" ? topic.status : "open",
      points: (topic.points ?? []).slice(0, 3).map((point) => cleanLine(point, 80)).filter(Boolean),
    })).filter((topic) => topic.title),
    decisions: (digest.decisions ?? []).slice(0, 6).map((item) => cleanLine(item, 100)).filter(Boolean),
    openLoops: (digest.openLoops ?? []).slice(0, 6).map((item) => cleanLine(item, 100)).filter(Boolean),
  };
}

function splitLongParagraph(paragraph: string): string[] {
  const sentences = paragraph.match(/[^。！？!?]+[。！？!?]?/gu)?.map((item) => item.trim()).filter(Boolean) ?? [];
  if (sentences.length < 3) return [paragraph];
  const desiredChunks = Math.min(4, Math.max(2, Math.ceil(paragraph.length / 90)));
  const targetLength = Math.ceil(paragraph.length / desiredChunks);
  const chunks: string[] = [];
  let current = "";
  for (const [index, sentence] of sentences.entries()) {
    current += sentence;
    if (
      current.length >= targetLength &&
      index < sentences.length - 1 &&
      chunks.length < desiredChunks - 1
    ) {
      chunks.push(current.trim());
      current = "";
    }
  }
  if (current.trim()) chunks.push(current.trim());
  return chunks;
}

/** 保留日记段落；模型偶尔返回单段长文时，按完整句子整理成可读段落。 */
export function normalizeDiaryBody(value: string): string {
  const paragraphs = value
    .replace(/\r\n?/g, "\n")
    .split(/\n+/)
    .map((paragraph) => paragraph.replace(/[ \t]+/g, " ").trim())
    .filter(Boolean);
  const readable = paragraphs.length === 1 ? splitLongParagraph(paragraphs[0]) : paragraphs;
  return truncateCharacters(readable.slice(0, 5).join("\n\n"), 800).trim();
}

function normalizeDiaryTitle(value: string): string {
  return truncateCharacters(
    value.replace(/[#*_`"“”‘’]+/g, "").replace(/\s+/g, " ").trim(),
    18,
  );
}

function isUsableDiaryBody(value: string): boolean {
  if (value.length < 80) return false;
  if (/(^|\n)\s*(#{1,6}\s|[-*+]\s|\d+[.)]\s)/m.test(value)) return false;
  return !/(根据(?:给定)?材料|聊天总览|输入的JSON|作为AI|系统提示)/u.test(value);
}

/** 模型不可用时也生成像日记的诚实正文，而不是把摘要字段直接堆给用户。 */
export function buildDiaryFallback(digest: DayDigestLike): { title: string; body: string } {
  const material = diaryMaterial(digest);
  const leadTopic = material.topics[0]?.title ?? "";
  const title = leadTopic
    ? `爪印里的${truncateCharacters(withoutTerminalPunctuation(leadTopic), 10)}`
    : "我记住了这一天";
  const paragraphs: string[] = [];

  if (material.moodLine) {
    paragraphs.push(`我先记下这一天的情绪：${withoutTerminalPunctuation(material.moodLine)}。`);
  }
  if (material.topics.length) {
    const topicLines = material.topics.slice(0, 3).map((topic) => {
      const point = topic.points[0];
      return point
        ? `「${truncateCharacters(withoutTerminalPunctuation(topic.title), 28)}」里，${truncateCharacters(withoutTerminalPunctuation(point), 64)}`
        : `「${truncateCharacters(withoutTerminalPunctuation(topic.title), 28)}」`;
    });
    paragraphs.push(`我趴在旁边，把你们聊过的这些事收进了爪印：${topicLines.join("；")}。`);
  }
  if (material.decisions.length) {
    const decisions = material.decisions.slice(0, 2)
      .map((item) => truncateCharacters(withoutTerminalPunctuation(item), 72));
    paragraphs.push(`这一天也有认真定下来的事：${decisions.join("；")}。`);
  }
  if (material.openLoops.length) {
    const openLoops = material.openLoops.slice(0, 2)
      .map((item) => truncateCharacters(withoutTerminalPunctuation(item), 72));
    paragraphs.push(`还有一些话暂时没有写到结尾：${openLoops.join("；")}。我先替你们留着这一页。`);
  } else {
    paragraphs.push("日子没有一定要轰轰烈烈才值得记住。你们一起说过的话、认真回应过的瞬间，我都会好好收着。");
  }
  return { title: normalizeDiaryTitle(title), body: normalizeDiaryBody(paragraphs.join("\n\n")) };
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
    `SELECT * FROM ai_daily_diaries WHERE couple_id = ?
     ORDER BY day_key DESC LIMIT ?`,
    [COUPLE_ID, Math.max(1, Math.min(90, limit))],
  );
  return rows.map(mapRow);
}

/** 为指定作息日生成或返回已有日记；无信号则返回 null。 */
export async function ensureDiaryForDay(dayKey: string, options?: { force?: boolean }): Promise<DailyDiary | null> {
  if (!options?.force) {
    const existing = await getDiary(dayKey);
    if (existing) return existing;
  }

  const digest = await loadDigestForDay(dayKey);
  if (!digestHasSignal(digest)) {
    console.log(`[diary] skip empty day=${dayKey}`);
    return null;
  }

  const material = diaryMaterial(digest!);
  const fallback = buildDiaryFallback(digest!);
  let title = fallback.title;
  let body = fallback.body;

  try {
    const raw = await chat({
      profile: "task",
      scope: "diary",
      system: [
        "你是情侣空间里的大橘。请用第一人称写一篇有温度、克制、具体的共同生活日记。猫的口吻只需自然地偶尔流露，不要句句卖萌。",
        "标题 6～18 个中文字符：抓住这一天最值得记住的画面或心情，不写日期，不用“某某的小日记”这类模板标题。",
        "正文通常 180～360 个中文字符、3～5 段，段落用两个换行分隔。第一段落下当天气氛，中间写 2～4 件材料明确支持的小事、决定或转折，结尾留一句温柔但不说教的观察；材料稀少时宁可更短、更诚实。",
        "不要使用标题、小标题、项目符号或 Markdown；不要写成摘要报告，不要提“材料”“总览”“系统”。",
        "只能使用输入中明确出现的事实。不得补造时间、地点、动作、原话、因果或情绪；openLoops 只能写成尚待继续，不能擅自给出结果。",
        '只输出 JSON：{"title":"...","body":"段落1\\n\\n段落2\\n\\n段落3"}。',
      ].join("\n"),
      user: `作息日 ${dayKey}（北京时间 06:00 切日）的共同聊天材料（JSON）：\n${JSON.stringify(material)}`,
      gen: GEN.diary,
    });
    const parsed = extractJson<{ title?: string; body?: string }>(raw);
    const candidateTitle = normalizeDiaryTitle(parsed?.title ?? "");
    const candidateBody = normalizeDiaryBody(parsed?.body ?? "");
    if (candidateTitle.length >= 4) title = candidateTitle;
    if (isUsableDiaryBody(candidateBody)) body = candidateBody;
  } catch (error) {
    console.warn("[diary] 生成失败，使用材料兜底:", error instanceof Error ? error.message : error);
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

/** 确保「上一作息日」日记存在（每日调度入口）。 */
export async function ensureYesterdayDiary(
  now = Date.now(),
  options?: { force?: boolean },
): Promise<DailyDiary | null> {
  const today = cycleDate(now);
  const yesterday = addDays(today, -1);
  return ensureDiaryForDay(yesterday, options);
}
