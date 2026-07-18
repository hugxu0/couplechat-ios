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

interface DayDigestLike {
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

function slimDigest(digest: DayDigestLike): string {
  const lines: string[] = [];
  if (digest.moodLine) lines.push(`情绪：${digest.moodLine}`);
  if (digest.decisions?.length) lines.push(`决定：${digest.decisions.slice(0, 6).join("；")}`);
  if (digest.openLoops?.length) lines.push(`未决：${digest.openLoops.slice(0, 6).join("；")}`);
  for (const topic of (digest.topics ?? []).slice(0, 12)) {
    const title = String(topic.title ?? "").trim();
    if (!title) continue;
    const point = topic.points?.[0] ? ` — ${topic.points[0]}` : "";
    lines.push(`- ${title}${point}`);
  }
  return lines.join("\n");
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

  const material = slimDigest(digest!);
  let title = `${dayKey} 的小日记`;
  let body = material.slice(0, 600) || "这一天有些安静，但你们仍在彼此身边。";

  try {
    const raw = await chat({
      profile: "task",
      scope: "diary",
      system:
        "你是情侣空间的大橘，用第一人称猫系口吻写「昨天」的短日记。只根据给定材料，不编造未出现的事实。输出 JSON：{\"title\":\"≤18字\",\"body\":\"120~280字，2~4段\"}",
      user: `作息日 ${dayKey}（北京时间 06:00 切日）的公聊总览材料：\n${material}`,
      gen: GEN.diary,
    });
    const parsed = extractJson<{ title?: string; body?: string }>(raw);
    if (parsed?.title?.trim()) title = parsed.title.replace(/\s+/g, " ").trim().slice(0, 40);
    if (parsed?.body?.trim()) body = parsed.body.replace(/\s+/g, " ").trim().slice(0, 800);
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
export async function ensureYesterdayDiary(now = Date.now()): Promise<DailyDiary | null> {
  const today = cycleDate(now);
  const yesterday = addDays(today, -1);
  return ensureDiaryForDay(yesterday);
}
