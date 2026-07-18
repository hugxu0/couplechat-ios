// 大橘日记：只读 couple 公聊日总览/归档，生成上一作息日的固定短日记。
// 不读取任一账号 AI 私聊。

import { nanoid } from "nanoid";
import { all, get, run } from "../../db";
import { chat, extractJson } from "../provider";
import { GEN } from "../settings";
import { readRuntimeState } from "../runtimeState";
import { compactLine, ownerConversationMessagesAround } from "../conversation/log";
import { addDays, cycleBounds, cycleDate } from "../time";

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
  topics?: Array<{
    id?: string;
    title?: string;
    status?: string;
    actors?: string[];
    points?: string[];
    lastAt?: number;
  }>;
  decisions?: string[];
  openLoops?: string[];
  moodLine?: string;
}

interface DiaryTopicMaterial {
  id: string;
  title: string;
  status: "open" | "done" | "dropped";
  actors: string[];
  points: string[];
  lastAt?: number;
}

interface DiaryTextMaterial {
  id: string;
  text: string;
}

interface DiaryMaterial {
  moodLine: string;
  topics: DiaryTopicMaterial[];
  decisions: DiaryTextMaterial[];
  openLoops: DiaryTextMaterial[];
}

export interface DiaryFocus {
  theme: string;
  topicIds: string[];
  decisionIds: string[];
  openLoopIds: string[];
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

function diaryMaterial(digest: DayDigestLike): DiaryMaterial {
  return {
    moodLine: cleanLine(digest.moodLine, 120),
    topics: (digest.topics ?? []).slice(0, 16).map((topic, index) => ({
      id: cleanLine(topic.id, 64) || `topic_${index}`,
      title: cleanLine(topic.title, 48),
      status: (topic.status === "done" || topic.status === "dropped"
        ? topic.status
        : "open") as DiaryTopicMaterial["status"],
      actors: (topic.actors ?? []).slice(0, 4).map((actor) => cleanLine(actor, 16)).filter(Boolean),
      points: (topic.points ?? []).slice(0, 3).map((point) => cleanLine(point, 90)).filter(Boolean),
      lastAt: Number.isFinite(topic.lastAt) ? Number(topic.lastAt) : undefined,
    })).filter((topic) => topic.title),
    decisions: (digest.decisions ?? []).slice(0, 8).map((item, index) => ({
      id: `decision_${index}`,
      text: cleanLine(item, 110),
    })).filter((item) => item.text),
    openLoops: (digest.openLoops ?? []).slice(0, 8).map((item, index) => ({
      id: `open_loop_${index}`,
      text: cleanLine(item, 110),
    })).filter((item) => item.text),
  };
}

const EMOTIONAL_TOPIC_PATTERN = /爱|想念|晚安|开心|难过|担心|不安|陪|安慰|拥抱|喜欢|关系|未来|一起|约定|争吵|和好|感谢|道歉|亲密/u;
const ROUTINE_TOPIC_PATTERN = /安装|版本|账号|设置|打不开|总价|称重|软件|设备|订车|提醒|计算/u;

function topicFallbackScore(topic: DiaryTopicMaterial): number {
  const text = `${topic.title} ${topic.points.join(" ")}`;
  const owners = new Set(topic.actors.filter((actor) => actor === "xu" || actor === "si"));
  let score = Math.min(2, topic.points.length) + (topic.status === "done" ? 0.5 : 0);
  if (topic.actors.includes("both") || owners.size === 2) score += 3;
  if (EMOTIONAL_TOPIC_PATTERN.test(text)) score += 4;
  if (ROUTINE_TOPIC_PATTERN.test(text)) score -= 2;
  return score;
}

function focusFromMaterial(material: DiaryMaterial): DiaryFocus {
  const rankedTopics = material.topics
    .map((topic, index) => ({ topic, index, score: topicFallbackScore(topic) }))
    .sort((a, b) => b.score - a.score || a.index - b.index);
  const topicIds = rankedTopics.length ? [rankedTopics[0].topic.id] : [];
  if (
    rankedTopics.length > 1 &&
    rankedTopics[1].score >= Math.max(3, rankedTopics[0].score - 1.5)
  ) {
    topicIds.push(rankedTopics[1].topic.id);
  }
  const leadTopic = material.topics.find((topic) => topic.id === topicIds[0]);
  return {
    theme: cleanLine(leadTopic?.title || material.moodLine || "这一天值得记住的片刻", 30),
    topicIds,
    decisionIds: !topicIds.length && material.decisions.length ? [material.decisions[0].id] : [],
    openLoopIds: !topicIds.length && !material.decisions.length && material.openLoops.length
      ? [material.openLoops[0].id]
      : [],
  };
}

/** 模型选材不可用时，仍只保留一条主线和至多一条陪衬。 */
export function selectFallbackDiaryFocus(digest: DayDigestLike): DiaryFocus {
  return focusFromMaterial(diaryMaterial(digest));
}

function selectedIds(value: unknown, allowed: Set<string>, limit: number): string[] {
  if (!Array.isArray(value)) return [];
  return [...new Set(value.map((item) => cleanLine(item, 64)).filter((id) => allowed.has(id)))].slice(0, limit);
}

async function curateDiaryFocus(material: DiaryMaterial): Promise<DiaryFocus> {
  const fallback = focusFromMaterial(material);
  try {
    const raw = await chat({
      profile: "task",
      scope: "diary.curate",
      system: [
        "你是共同日记的选材编辑，只负责取舍，不写正文。",
        "从当天材料中选出一条真正值得记住的主线，最多再选一条与主线直接相关的陪衬。优先亲密、情绪变化、彼此照顾、共同决定或关系转折；普通寒暄、购物清单、软件设备、零碎计算和流水事项通常舍弃，除非它们正是关系主线的关键。",
        "不要为了覆盖材料而多选。决定和未决事项各最多一个，且只有与所选主线直接相关才选；无法判断关联时留空。",
        "theme 用 8～24 个中文字符概括主线，不补造事实。所有 ID 只能从输入原样选择。",
        '只输出 JSON：{"theme":"...","topicIds":["..."],"decisionIds":[],"openLoopIds":[]}。',
      ].join("\n"),
      user: `候选材料（JSON）：\n${JSON.stringify(material)}`,
      gen: GEN.diaryCurate,
    });
    const parsed = extractJson<{
      theme?: string;
      topicIds?: unknown;
      decisionIds?: unknown;
      openLoopIds?: unknown;
    }>(raw);
    const topicIds = selectedIds(parsed?.topicIds, new Set(material.topics.map((item) => item.id)), 2);
    const decisionIds = selectedIds(
      parsed?.decisionIds,
      new Set(material.decisions.map((item) => item.id)),
      1,
    );
    const openLoopIds = selectedIds(
      parsed?.openLoopIds,
      new Set(material.openLoops.map((item) => item.id)),
      1,
    );
    if (!topicIds.length && !decisionIds.length && !openLoopIds.length) return fallback;
    const leadTopic = material.topics.find((topic) => topic.id === topicIds[0]);
    return {
      theme: cleanLine(parsed?.theme || leadTopic?.title || fallback.theme, 30),
      topicIds,
      decisionIds,
      openLoopIds,
    };
  } catch (error) {
    console.warn("[diary] 选材失败，使用本地聚焦:", error instanceof Error ? error.message : error);
    return fallback;
  }
}

function focusedDiaryMaterial(material: DiaryMaterial, focus: DiaryFocus) {
  const topicIds = new Set(focus.topicIds);
  const decisionIds = new Set(focus.decisionIds);
  const openLoopIds = new Set(focus.openLoopIds);
  return {
    theme: focus.theme,
    moodLine: material.moodLine,
    topics: material.topics.filter((item) => topicIds.has(item.id)),
    decisions: material.decisions.filter((item) => decisionIds.has(item.id)).map((item) => item.text),
    openLoops: material.openLoops.filter((item) => openLoopIds.has(item.id)).map((item) => item.text),
  };
}

async function diarySourceLines(dayKey: string, topics: DiaryTopicMaterial[]): Promise<string[]> {
  const { start, end } = cycleBounds(dayKey);
  const anchoredTopics = topics.filter((topic) => topic.lastAt && topic.lastAt >= start && topic.lastAt < end);
  const batches = await Promise.all(anchoredTopics.map((topic) => {
    const anchor = topic.lastAt!;
    return ownerConversationMessagesAround(
      CHANNEL,
      anchor,
      Math.max(start, anchor - 20 * 60 * 1000),
      Math.min(end, anchor + 12 * 60 * 1000),
      12,
    );
  }));
  const unique = new Map(batches.flat().map((message) => [message.id, message]));
  return [...unique.values()]
    .sort((a, b) => a.ts - b.ts || a.id.localeCompare(b.id))
    .map((message) => compactLine(message, 110))
    .filter(Boolean)
    .slice(0, 20);
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
  return truncateCharacters(readable.slice(0, 4).join("\n\n"), 600).trim();
}

function normalizeDiaryTitle(value: string): string {
  return truncateCharacters(
    value.replace(/[#*_`"“”‘’]+/g, "").replace(/\s+/g, " ").trim(),
    18,
  );
}

export function isUsableDiaryBody(value: string): boolean {
  if (value.length < 70 || value.length > 520) return false;
  if (/(^|\n)\s*(#{1,6}\s|[-*+]\s|\d+[.)]\s)/m.test(value)) return false;
  if ((value.match(/[；;]/gu)?.length ?? 0) >= 2) return false;
  return !/(根据(?:给定)?材料|聊天总览|输入的JSON|作为AI|系统提示|聊了好多|逐一记录|收进了爪印：)/u.test(value);
}

/** 模型不可用时也只围绕选中的主线写，绝不把整份摘要字段逐项堆给用户。 */
export function buildDiaryFallback(
  digest: DayDigestLike,
  selectedFocus?: DiaryFocus,
): { title: string; body: string } {
  const material = diaryMaterial(digest);
  const focus = selectedFocus ?? focusFromMaterial(material);
  const focused = focusedDiaryMaterial(material, focus);
  const leadTopic = focused.topics[0];
  const titleSeed = focus.theme || leadTopic?.title || "这一天值得记住的片刻";
  const title = `爪印里的${truncateCharacters(withoutTerminalPunctuation(titleSeed), 10)}`;
  const paragraphs: string[] = [];

  const mood = focused.moodLine
    ? ` ${truncateCharacters(withoutTerminalPunctuation(focused.moodLine), 72)}。`
    : "";
  paragraphs.push(`这一天，我最想记住的是${withoutTerminalPunctuation(titleSeed)}。${mood}`.trim());

  if (leadTopic) {
    const point = leadTopic.points[0];
    const detail = point
      ? ` ${truncateCharacters(withoutTerminalPunctuation(point), 88)}。`
      : "";
    paragraphs.push(`你们把“${truncateCharacters(withoutTerminalPunctuation(leadTopic.title), 32)}”认真放在了两个人之间。${detail}`.trim());
  }
  const supportingTopic = focused.topics[1];
  if (supportingTopic) {
    const point = supportingTopic.points[0];
    paragraphs.push(
      point
        ? `与它相连的另一幕是“${truncateCharacters(withoutTerminalPunctuation(supportingTopic.title), 28)}”。${truncateCharacters(withoutTerminalPunctuation(point), 78)}。`
        : `与它相连的另一幕，是你们也认真说起了“${truncateCharacters(withoutTerminalPunctuation(supportingTopic.title), 28)}”。`,
    );
  }

  const ending: string[] = [];
  if (focused.decisions[0]) {
    ending.push(`后来，你们把${truncateCharacters(withoutTerminalPunctuation(focused.decisions[0]), 76)}定了下来。`);
  }
  if (focused.openLoops[0]) {
    ending.push(`至于${truncateCharacters(withoutTerminalPunctuation(focused.openLoops[0]), 76)}，还没有走到结尾，我先替你们留一小块空白。`);
  }
  ending.push("日子不必把每一件小事都写满；真正被彼此接住的那一刻，已经足够留下一枚爪印。");
  paragraphs.push(ending.join(""));
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
  const focus = await curateDiaryFocus(material);
  const focused = focusedDiaryMaterial(material, focus);
  let sourceLines: string[] = [];
  try {
    sourceLines = await diarySourceLines(dayKey, focused.topics);
  } catch (error) {
    console.warn("[diary] 相关原文读取失败，仅使用聚焦总览:", error instanceof Error ? error.message : error);
  }
  const fallback = buildDiaryFallback(digest!, focus);
  let title = fallback.title;
  let body = fallback.body;

  try {
    const raw = await chat({
      profile: "task",
      scope: "diary",
      system: [
        "你是情侣空间里的大橘。用第一人称写一页有温度、克制、具体的共同生活日记；猫的口吻只需偶尔自然流露。",
        "编辑已经替你选好主线。整篇只围绕 theme 和第一条 topic 展开，第二条 topic 仅在自然相连时轻轻带过；绝不能把输入字段逐项复述，也不要试图交代完整的一天。",
        "sourceLines 是所选话题时间点附近的少量共同聊天原文，只用来恢复真实顺序、语气和细节。不要大段照抄原话，不要把无关事项从原文重新捡回来。",
        "标题 6～16 个中文字符，抓住最值得记住的画面或心情，不写日期，不用模板标题。",
        "正文通常 120～280 个中文字符、2～4 个自然段。先落下一幕或一种心情，再写彼此如何回应或事情如何变化，最后留一句温柔但不说教的观察；材料少时宁可短，不凑字数。",
        "不要使用小标题、项目符号、Markdown、冒号清单或连续分号；不要写“聊了好多”“还聊到”“逐一记录”，不要以“昨天，本橘陪你们”开头，不要写成摘要报告。",
        "只能使用输入中明确出现的事实。不得补造时间、地点、动作、原话、因果或情绪；openLoops 只能写成尚待继续，不能擅自给出结果。",
        '只输出 JSON：{"title":"...","body":"段落1\\n\\n段落2\\n\\n段落3"}。',
      ].join("\n"),
      user: `作息日 ${dayKey}（北京时间 06:00 切日）的已筛选材料（JSON）：\n${JSON.stringify({
        ...focused,
        sourceLines,
      })}`,
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
