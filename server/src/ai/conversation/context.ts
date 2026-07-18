// 对话上下文 v2：热窗口原文 + 微段 + 作息日当日总览。
// 目标：一天约 1000 条公聊时，晚上仍能知道早上聊过的话题大概。

import { nanoid } from "nanoid";
import { get } from "../../db";
import { compactLine, compactLines, messagesAfter, recentConversationMessages, type LogMessage } from "./log";
import { CONTEXT, GEN } from "../settings";
import { chat, extractJson } from "../provider";
import { readRuntimeState, writeRuntimeState } from "../runtimeState";
import { addDays, beijingClock, cycleBounds, cycleDate } from "../time";
import { isLowSignalText } from "../textSignals";

export const CONVERSATION_FOCUS_MESSAGES = CONTEXT.recentFocusCount;
export const CONVERSATION_MAX_MESSAGES = CONTEXT.recentMaxCount;

const STATE_KEY_PREFIX = "context:v2:";
const DAY_ARCHIVE_PREFIX = "context:v2:day:";

type TopicStatus = "open" | "done" | "dropped";
type TopicActor = "xu" | "si" | "both" | "daju";

interface Cursor {
  ts: number;
  id: string;
}

interface DaySegment {
  id: string;
  dayKey: string;
  from: Cursor;
  to: Cursor;
  messageCount: number;
  timeRangeLabel: string;
  bullets: string[];
}

interface DayTopic {
  id: string;
  title: string;
  status: TopicStatus;
  actors: TopicActor[];
  points: string[];
  lastAt: number;
}

interface DayDigest {
  dayKey: string;
  topics: DayTopic[];
  decisions: string[];
  openLoops: string[];
  moodLine: string;
  updatedAt: number;
}

interface ChannelContextState {
  strategy: "day-digest-v2";
  rawCursor: Cursor;
  dayKey: string;
  dayDigest: DayDigest;
  /** 已折入 digest 的最近微段，供 prompt 展示时段粒度 */
  recentSegments: DaySegment[];
  pendingSegments: DaySegment[];
  lastError?: { at: number; message: string };
  /** 游标之后仍有未压消息时，在 prompt 中提示 */
  lagMessageCount?: number;
}

export interface ConversationContext {
  dayKey: string;
  dayDigestText: string;
  yesterdayTitlesText: string;
  recentSegmentsText: string;
  supplemental: LogMessage[];
  focus: LogMessage[];
  recent: LogMessage[];
  turnCount: number;
  lagMessageCount: number;
  catchUpIncomplete: boolean;
}

const updateChains = new Map<string, Promise<void>>();
const scheduleTimers = new Map<string, NodeJS.Timeout>();

function stateKey(channel: string): string {
  return `${STATE_KEY_PREFIX}${channel}`;
}

function emptyDigest(dayKey: string): DayDigest {
  return {
    dayKey,
    topics: [],
    decisions: [],
    openLoops: [],
    moodLine: "",
    updatedAt: Date.now(),
  };
}

function emptyState(_channel: string, now = Date.now()): ChannelContextState {
  const dayKey = cycleDate(now);
  const { start } = cycleBounds(dayKey);
  return {
    strategy: "day-digest-v2",
    rawCursor: { ts: start, id: "" },
    dayKey,
    dayDigest: emptyDigest(dayKey),
    recentSegments: [],
    pendingSegments: [],
  };
}

function isCursor(value: unknown): value is Cursor {
  if (!value || typeof value !== "object") return false;
  const cursor = value as Cursor;
  return typeof cursor.ts === "number" && Number.isFinite(cursor.ts) && typeof cursor.id === "string";
}

function sanitizeTopicStatus(value: unknown): TopicStatus {
  return value === "done" || value === "dropped" ? value : "open";
}

function sanitizeActors(value: unknown): TopicActor[] {
  if (!Array.isArray(value)) return ["both"];
  const allowed = new Set<TopicActor>(["xu", "si", "both", "daju"]);
  const actors = value
    .map((item) => String(item).trim().toLowerCase())
    .filter((item): item is TopicActor => allowed.has(item as TopicActor));
  return actors.length ? [...new Set(actors)] : ["both"];
}

function parseState(raw: string, channel: string): ChannelContextState {
  const fallback = emptyState(channel);
  if (!raw) return fallback;
  try {
    const parsed = JSON.parse(raw) as Partial<ChannelContextState>;
    if (parsed.strategy !== "day-digest-v2") return fallback;
    const dayKey = typeof parsed.dayKey === "string" && parsed.dayKey ? parsed.dayKey : fallback.dayKey;
    const digest = parsed.dayDigest && typeof parsed.dayDigest === "object"
      ? {
          dayKey: String((parsed.dayDigest as DayDigest).dayKey || dayKey),
          topics: Array.isArray((parsed.dayDigest as DayDigest).topics)
            ? (parsed.dayDigest as DayDigest).topics.map((topic, index) => ({
                id: String(topic?.id || `topic_${index}`).slice(0, 40),
                title: String(topic?.title || "未命名话题").replace(/\s+/g, " ").trim().slice(0, 40),
                status: sanitizeTopicStatus(topic?.status),
                actors: sanitizeActors(topic?.actors),
                points: Array.isArray(topic?.points)
                  ? topic.points.map((point) => String(point).replace(/\s+/g, " ").trim()).filter(Boolean).slice(0, 8)
                  : [],
                lastAt: Number(topic?.lastAt) || 0,
              }))
            : [],
          decisions: Array.isArray((parsed.dayDigest as DayDigest).decisions)
            ? (parsed.dayDigest as DayDigest).decisions.map((item) => String(item).trim()).filter(Boolean).slice(0, 20)
            : [],
          openLoops: Array.isArray((parsed.dayDigest as DayDigest).openLoops)
            ? (parsed.dayDigest as DayDigest).openLoops.map((item) => String(item).trim()).filter(Boolean).slice(0, 20)
            : [],
          moodLine: String((parsed.dayDigest as DayDigest).moodLine || "").replace(/\s+/g, " ").trim().slice(0, 120),
          updatedAt: Number((parsed.dayDigest as DayDigest).updatedAt) || Date.now(),
        }
      : emptyDigest(dayKey);
    return {
      strategy: "day-digest-v2",
      rawCursor: isCursor(parsed.rawCursor) ? parsed.rawCursor : fallback.rawCursor,
      dayKey,
      dayDigest: digest,
      recentSegments: Array.isArray(parsed.recentSegments) ? parsed.recentSegments.filter(Boolean).slice(-8) as DaySegment[] : [],
      pendingSegments: Array.isArray(parsed.pendingSegments) ? parsed.pendingSegments.filter(Boolean).slice(0, 8) as DaySegment[] : [],
      lastError: parsed.lastError && typeof parsed.lastError === "object"
        ? {
            at: Number((parsed.lastError as { at?: number }).at) || Date.now(),
            message: String((parsed.lastError as { message?: string }).message || "").slice(0, 300),
          }
        : undefined,
      lagMessageCount: Number(parsed.lagMessageCount) || 0,
    };
  } catch {
    return fallback;
  }
}

async function loadState(channel: string): Promise<ChannelContextState> {
  return parseState(await readRuntimeState(stateKey(channel)), channel);
}

async function saveState(channel: string, state: ChannelContextState): Promise<void> {
  await writeRuntimeState(stateKey(channel), JSON.stringify(state));
}

function isContextMessage(message: LogMessage): boolean {
  if (message.kind === "system") return false;
  if (message.type === "sticker") return false;
  if (message.type === "text" && isLowSignalText(message.text)) return false;
  return Boolean(compactLine(message));
}

async function loadYesterdayTitles(channel: string, dayKey: string): Promise<string> {
  const yesterday = addDays(dayKey, -1);
  const raw = await readRuntimeState(`${DAY_ARCHIVE_PREFIX}${channel}:${yesterday}`);
  if (!raw) return "";
  try {
    const parsed = JSON.parse(raw) as Partial<DayDigest>;
    const titles = Array.isArray(parsed.topics)
      ? parsed.topics
        .map((topic) => String(topic?.title ?? "").replace(/\s+/g, " ").trim())
        .filter(Boolean)
        .slice(0, 12)
      : [];
    if (!titles.length) return "";
    return `作息日 ${yesterday}：${titles.join("、")}`;
  } catch {
    return "";
  }
}

function compareCursor(a: Cursor, b: Cursor): number {
  if (a.ts !== b.ts) return a.ts - b.ts;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

function timeRangeLabel(messages: LogMessage[]): string {
  if (!messages.length) return "";
  const first = messages[0];
  const last = messages[messages.length - 1];
  const a = beijingClock(first.ts);
  const b = beijingClock(last.ts);
  return a === b ? a : `${a}–${b}`;
}

async function rollDayIfNeeded(channel: string, state: ChannelContextState, now = Date.now()): Promise<ChannelContextState> {
  const today = cycleDate(now);
  if (state.dayKey === today) return state;

  // 先尽量把昨日 pending 折进去，再归档。
  if (state.pendingSegments.length) {
    state.dayDigest = await mergeSegmentsIntoDigest(state.dayDigest, state.pendingSegments);
    state.pendingSegments = [];
  }

  if (state.dayDigest.topics.length || state.dayDigest.decisions.length || state.dayDigest.openLoops.length) {
    await writeRuntimeState(
      `${DAY_ARCHIVE_PREFIX}${channel}:${state.dayKey}`,
      JSON.stringify(state.dayDigest),
    );
  }

  const { start } = cycleBounds(today);
  const next: ChannelContextState = {
    strategy: "day-digest-v2",
    rawCursor: compareCursor(state.rawCursor, { ts: start, id: "" }) < 0
      ? { ts: start, id: "" }
      : state.rawCursor,
    dayKey: today,
    dayDigest: emptyDigest(today),
    recentSegments: [],
    pendingSegments: [],
  };
  await saveState(channel, next);
  return next;
}

function shouldFlushSegment(
  buffer: LogMessage[],
  now: number,
  options: { force: boolean; noMore: boolean },
): boolean {
  if (!buffer.length) return false;
  if (buffer.length >= CONTEXT.segmentMessageCount) return true;
  if (options.force && options.noMore && buffer.length > 0) return true;
  if (buffer.length >= CONTEXT.segmentMinMessages) {
    const idle = now - buffer[buffer.length - 1].ts;
    if (idle >= CONTEXT.segmentIdleMs) return true;
  }
  const age = now - buffer[0].ts;
  if (buffer.length >= 1 && age >= CONTEXT.segmentMaxAgeMs) return true;
  if (options.noMore && buffer.length >= CONTEXT.segmentMinMessages) return true;
  return false;
}

function fallbackSegmentBullets(messages: LogMessage[]): string[] {
  return [
    `${timeRangeLabel(messages)} 约 ${messages.length} 条消息`,
    ...messages.slice(0, 4).map((message) => compactLine(message, 80)).filter(Boolean),
  ].slice(0, 6);
}

async function generateSegment(
  channel: string,
  dayKey: string,
  messages: LogMessage[],
): Promise<DaySegment> {
  const base = {
    id: `seg_${nanoid(10)}`,
    dayKey,
    from: { ts: messages[0].ts, id: messages[0].id },
    to: { ts: messages[messages.length - 1].ts, id: messages[messages.length - 1].id },
    messageCount: messages.length,
    timeRangeLabel: timeRangeLabel(messages),
  };
  const output = await chat({
    profile: "task",
    system:
      '时段要点整理。输出JSON {"bullets":["..."]} 5~8条≤60字。保留话题/人物/时间/决定/否定/未决/情绪；删寒暄；不编造。',
    user: [
      `${dayKey} ${timeRangeLabel(messages)} ch=${channel}`,
      messages.map((message) => compactLine(message, 120)).filter(Boolean).join("\n"),
    ].join("\n"),
    gen: GEN.contextSummary,
  });
  const parsed = extractJson<{ bullets?: unknown }>(output);
  const bullets = Array.isArray(parsed?.bullets)
    ? parsed!.bullets.map((item) => String(item ?? "").replace(/\s+/g, " ").trim()).filter(Boolean).slice(0, 8)
    : [];
  return {
    ...base,
    // 模型失败时用极简兜底，保证游标可推进、当天总览不空白。
    bullets: bullets.length ? bullets : fallbackSegmentBullets(messages),
  };
}

async function commitSegment(
  channel: string,
  state: ChannelContextState,
  messages: LogMessage[],
): Promise<void> {
  if (!messages.length) return;
  const segment = await generateSegment(channel, state.dayKey, messages);
  state.pendingSegments.push(segment);
  state.recentSegments = [...state.recentSegments, segment].slice(-8);
  state.rawCursor = segment.to;
  state.dayDigest = await mergeSegmentsIntoDigest(state.dayDigest, state.pendingSegments);
  state.pendingSegments = [];
  state.lastError = undefined;
  await saveState(channel, state);

  // 公聊：微段折入日总览后，用精简上下文做冲突/搭话分类（不阻塞追赶）。
  if (channel === "couple") {
    const { notifyCoupleSegmentCommitted } = await import("../engagement");
    notifyCoupleSegmentCommitted({
      digest: {
        dayKey: state.dayDigest.dayKey,
        topics: state.dayDigest.topics.map((topic) => ({
          title: topic.title,
          status: topic.status,
          points: topic.points,
        })),
        openLoops: state.dayDigest.openLoops,
        decisions: state.dayDigest.decisions,
        moodLine: state.dayDigest.moodLine,
      },
      segment: {
        id: segment.id,
        dayKey: segment.dayKey,
        timeRangeLabel: segment.timeRangeLabel,
        messageCount: segment.messageCount,
        bullets: segment.bullets,
      },
    });
  }
}

async function mergeSegmentsIntoDigest(
  digest: DayDigest,
  segments: DaySegment[],
): Promise<DayDigest> {
  if (!segments.length) return digest;
  // user 只送瘦身 JSON，避免把空字段/长元数据反复回灌。
  const slimDigest = {
    dayKey: digest.dayKey,
    topics: digest.topics.slice(0, CONTEXT.dayTopicMax).map((topic) => ({
      id: topic.id,
      title: topic.title,
      status: topic.status,
      actors: topic.actors,
      points: topic.points.slice(0, 4),
      lastAt: topic.lastAt,
    })),
    decisions: digest.decisions.slice(0, 12),
    openLoops: digest.openLoops.slice(0, 12),
    moodLine: digest.moodLine,
  };
  const slimSegments = segments.map((segment) => ({
    t: segment.timeRangeLabel,
    ts: segment.to.ts,
    b: segment.bullets,
  }));
  const output = await chat({
    profile: "task",
    system:
      '合并当日聊天总览。输出JSON：{"topics":[{"id","title","status":"open|done|dropped","actors":["xu|si|both|daju"],"points":[],"lastAt":0}],"decisions":[],"openLoops":[],"moodLine":""}。同话题复用id；points每话题≤5；topics≤24；不编造；lastAt毫秒。',
    user: `旧:${JSON.stringify(slimDigest)}\n新段:${JSON.stringify(slimSegments)}`,
    gen: { ...GEN.contextSummary, maxTokens: 1800, timeoutMs: 45_000 },
  });
  const latestSegmentAt = segments.reduce((max, segment) => Math.max(max, segment.to.ts), 0);
  const localFallback = (): DayDigest => {
    const points = segments.flatMap((segment) => segment.bullets).slice(0, 12);
    const excerpt: DayTopic = {
      id: `topic_seg_${segments[0]?.id || nanoid(6)}`,
      title: segments.length === 1
        ? (segments[0].timeRangeLabel || "时段摘录")
        : "今日摘录",
      status: "open",
      actors: ["both"],
      points,
      lastAt: latestSegmentAt,
    };
    const topics = [...digest.topics.filter((topic) => topic.id !== excerpt.id), excerpt]
      .sort((a, b) => b.lastAt - a.lastAt)
      .slice(0, CONTEXT.dayTopicMax);
    return {
      dayKey: digest.dayKey,
      topics,
      decisions: digest.decisions,
      openLoops: digest.openLoops,
      moodLine: digest.moodLine,
      updatedAt: Date.now(),
    };
  };

  const parsed = extractJson<{
    topics?: unknown;
    decisions?: unknown;
    openLoops?: unknown;
    moodLine?: unknown;
  }>(output);
  if (!parsed || !Array.isArray(parsed.topics)) return localFallback();

  const topics: DayTopic[] = parsed.topics.slice(0, CONTEXT.dayTopicMax).map((topic, index) => {
    const row = topic as Partial<DayTopic>;
    return {
      id: String(row.id || `topic_${index + 1}`).replace(/\s+/g, "_").slice(0, 40),
      title: String(row.title || "未命名话题").replace(/\s+/g, " ").trim().slice(0, 40),
      status: sanitizeTopicStatus(row.status),
      actors: sanitizeActors(row.actors),
      points: Array.isArray(row.points)
        ? row.points.map((point) => String(point).replace(/\s+/g, " ").trim()).filter(Boolean).slice(0, 8)
        : [],
      lastAt: Number(row.lastAt) || latestSegmentAt,
    };
  });

  if (!topics.length) return localFallback();

  return {
    dayKey: digest.dayKey,
    topics,
    decisions: Array.isArray(parsed.decisions)
      ? parsed.decisions.map((item) => String(item).trim()).filter(Boolean).slice(0, 20)
      : digest.decisions,
    openLoops: Array.isArray(parsed.openLoops)
      ? parsed.openLoops.map((item) => String(item).trim()).filter(Boolean).slice(0, 20)
      : digest.openLoops,
    moodLine: String(parsed.moodLine ?? digest.moodLine ?? "").replace(/\s+/g, " ").trim().slice(0, 120),
    updatedAt: Date.now(),
  };
}

async function countLag(channel: string, cursor: Cursor): Promise<number> {
  // 精确计数，避免 500 扫描上限低估「未消化」条数。
  const row = await get<{ count: string | number }>(
    `SELECT COUNT(*)::text AS count FROM messages
      WHERE channel = ?
        AND (ts > ? OR (ts = ? AND id > ?))
        AND kind <> 'system'`,
    [channel, cursor.ts, cursor.ts, cursor.id],
  );
  const count = Number(row?.count ?? 0);
  return Number.isFinite(count) ? count : 0;
}

export async function ensureContextCaughtUp(
  channel: string,
  options: { force?: boolean; budgetMs?: number } = {},
): Promise<{ incomplete: boolean; lagMessageCount: number }> {
  const force = Boolean(options.force);
  const budgetMs = options.budgetMs ?? CONTEXT.catchUpBudgetMs;
  const started = Date.now();

  // 同频道串行，避免并发写坏游标。
  const previous = updateChains.get(channel) ?? Promise.resolve();
  let result = { incomplete: false, lagMessageCount: 0 };
  const next = previous
    .catch(() => undefined)
    .then(async () => {
      result = await runCatchUp(channel, force, budgetMs, started);
    });
  updateChains.set(channel, next.then(() => undefined));
  await next;
  return result;
}

async function runCatchUp(
  channel: string,
  force: boolean,
  budgetMs: number,
  started: number,
): Promise<{ incomplete: boolean; lagMessageCount: number }> {
  let state = await loadState(channel);
  state = await rollDayIfNeeded(channel, state);

  const buffer: LogMessage[] = [];
  /** 扫描游标：可超前于已提交 rawCursor，避免同一轮重复拉页。 */
  let scanCursor: Cursor = { ...state.rawCursor };
  let incomplete = false;
  const timeLeft = () => budgetMs - (Date.now() - started);

  const flushTake = async (count: number) => {
    if (count <= 0 || !buffer.length) return;
    const take = Math.min(count, buffer.length);
    const chunk = buffer.splice(0, take);
    await commitSegment(channel, state, chunk);
  };

  while (timeLeft() > 1_500) {
    const page = await messagesAfter(channel, scanCursor, CONTEXT.catchUpPageSize);
    if (!page.length) break;

    let hitNextDay: LogMessage | null = null;

    for (const message of page) {
      scanCursor = { ts: message.ts, id: message.id };

      if (cycleDate(message.ts) !== state.dayKey) {
        hitNextDay = message;
        break;
      }
      if (!isContextMessage(message)) {
        // 仅在没有未提交缓冲时推进已提交游标，避免跳过缓冲中的有效消息。
        if (!buffer.length) {
          state.rawCursor = { ts: message.ts, id: message.id };
        }
        continue;
      }
      buffer.push(message);

      if (buffer.length >= CONTEXT.segmentMessageCount) {
        await flushTake(CONTEXT.segmentMessageCount);
        if (timeLeft() <= 1_500) {
          incomplete = true;
          break;
        }
      }
    }

    if (incomplete) break;

    if (hitNextDay) {
      if (buffer.length) await flushTake(buffer.length);
      await saveState(channel, state);
      state = await rollDayIfNeeded(channel, state, hitNextDay.ts);
      // 切日后从新日起点继续；scanCursor 仍指向跨日消息，下轮 messagesAfter 会从其后开始。
      // 若 rawCursor 被 roll 到新日起点且仍 < 跨日消息，需保证不丢跨日当天消息：
      // rollDayIfNeeded 在 rawCursor 已较新时保留 rawCursor；跨日消息尚未提交。
      // 将 scanCursor 回退到 rawCursor，使跨日消息能被重新扫描进新 day。
      scanCursor = { ...state.rawCursor };
      continue;
    }

    const noMore = page.length < CONTEXT.catchUpPageSize;
    if (shouldFlushSegment(buffer, Date.now(), { force, noMore })) {
      await flushTake(buffer.length);
    } else {
      await saveState(channel, state);
    }

    if (noMore) break;
    if (timeLeft() <= 1_500) {
      incomplete = true;
      break;
    }
  }

  if (!incomplete && buffer.length && force && timeLeft() > 2_000) {
    await flushTake(buffer.length);
  }

  if (state.pendingSegments.length && timeLeft() > 2_000) {
    state.dayDigest = await mergeSegmentsIntoDigest(state.dayDigest, state.pendingSegments);
    state.pendingSegments = [];
    state.lastError = undefined;
  }

  // 未提交缓冲不推进 rawCursor；下次从已提交点重读。
  if (buffer.length) incomplete = true;

  const lagMessageCount = await countLag(channel, state.rawCursor);
  state.lagMessageCount = lagMessageCount;
  if (lagMessageCount > 0) incomplete = true;
  await saveState(channel, state);
  return { incomplete, lagMessageCount };
}

/** 落后时后台继续追赶的预算（毫秒），不阻塞发送。 */
const BACKGROUND_CATCHUP_BUDGET_MS = 120_000;
const BACKGROUND_CATCHUP_GAP_MS = 5_000;
const backgroundTimers = new Map<string, ReturnType<typeof setTimeout>>();

function scheduleBackgroundCatchUp(channel: string): void {
  if (backgroundTimers.has(channel)) return;
  backgroundTimers.set(
    channel,
    setTimeout(() => {
      backgroundTimers.delete(channel);
      void ensureContextCaughtUp(channel, {
        force: true,
        budgetMs: BACKGROUND_CATCHUP_BUDGET_MS,
      })
        .then((result) => {
          if (result.incomplete) {
            console.log(
              `[context] ${channel} 后台追赶未完成 lag≈${result.lagMessageCount}，继续排队`,
            );
            scheduleBackgroundCatchUp(channel);
          }
        })
        .catch((error) => {
          console.warn(
            `[context] ${channel} 后台追赶失败:`,
            error instanceof Error ? error.message : error,
          );
          scheduleBackgroundCatchUp(channel);
        });
    }, BACKGROUND_CATCHUP_GAP_MS),
  );
}

/** 新消息后防抖追赶（不阻塞发送路径）。落后时自动转入后台长预算追赶。 */
export function scheduleContextCatchUp(channel: string): void {
  const existing = scheduleTimers.get(channel);
  if (existing) clearTimeout(existing);
  scheduleTimers.set(channel, setTimeout(() => {
    scheduleTimers.delete(channel);
    void ensureContextCaughtUp(channel, {
      force: false,
      budgetMs: CONTEXT.catchUpBudgetMs,
    })
      .then((result) => {
        if (result.incomplete) scheduleBackgroundCatchUp(channel);
      })
      .catch((error) => {
        console.warn(
          `[context] ${channel} 追赶失败:`,
          error instanceof Error ? error.message : error,
        );
        scheduleBackgroundCatchUp(channel);
      });
  }, CONTEXT.scheduleDebounceMs));
}

/** 兼容旧调用：回复结束后再追一次，纳入大橘刚说的话。 */
export function updateConversationContext(channel: string, _triggerMessageId?: string): Promise<void> {
  scheduleContextCatchUp(channel);
  return Promise.resolve();
}

export function splitConversationMessages(messages: LogMessage[]) {
  return {
    supplemental: messages.slice(0, Math.max(0, messages.length - CONVERSATION_FOCUS_MESSAGES)),
    focus: messages.slice(-CONVERSATION_FOCUS_MESSAGES),
  };
}

function renderDayDigest(digest: DayDigest, maxChars: number): string {
  if (!digest.topics.length && !digest.decisions.length && !digest.openLoops.length && !digest.moodLine) {
    return "";
  }
  const lines: string[] = [`作息日 ${digest.dayKey}（北京时间 06:00 起算）`];
  if (digest.topics.length) {
    lines.push("话题：");
    for (const topic of digest.topics) {
      const status = topic.status === "open" ? "进行中" : topic.status === "done" ? "已结束" : "搁置";
      const actors = topic.actors.join("/");
      lines.push(`- ${topic.title}（${status}，${actors}）`);
      for (const point of topic.points.slice(0, 6)) {
        lines.push(`  · ${point}`);
      }
    }
  }
  if (digest.decisions.length) {
    lines.push(`决定：${digest.decisions.join("；")}`);
  }
  if (digest.openLoops.length) {
    lines.push(`未决：${digest.openLoops.join("；")}`);
  }
  if (digest.moodLine) {
    lines.push(`情绪：${digest.moodLine}`);
  }
  let text = lines.join("\n");
  if (text.length > maxChars) {
    text = `${text.slice(0, maxChars - 12)}\n…（总览已截断）`;
  }
  return text;
}

function renderRecentSegments(segments: DaySegment[], max: number): string {
  const chosen = segments.slice(-max);
  if (!chosen.length) return "";
  return chosen.map((segment) => {
    const bullets = segment.bullets.map((item) => `  · ${item}`).join("\n");
    return `${segment.timeRangeLabel}（${segment.messageCount}条）\n${bullets}`;
  }).join("\n");
}

export async function buildConversationContext(
  channel: string,
  currentMessageId?: string,
): Promise<ConversationContext> {
  const catchUp = await ensureContextCaughtUp(channel, {
    force: true,
    budgetMs: CONTEXT.catchUpBudgetMs,
  });
  const state = await loadState(channel);
  const [recent, yesterdayTitlesText] = await Promise.all([
    recentConversationMessages(channel, CONVERSATION_MAX_MESSAGES, currentMessageId),
    loadYesterdayTitles(channel, state.dayKey),
  ]);
  const visible = recent.filter((message) => message.kind !== "system");
  const { supplemental, focus } = splitConversationMessages(visible);

  return {
    dayKey: state.dayKey,
    dayDigestText: renderDayDigest(state.dayDigest, CONTEXT.dayDigestMaxChars),
    yesterdayTitlesText,
    recentSegmentsText: renderRecentSegments(state.recentSegments, CONTEXT.pendingSegmentPromptMax),
    supplemental,
    focus,
    recent: visible,
    turnCount: visible.filter((message) => message.sender === "ai").length,
    lagMessageCount: catchUp.lagMessageCount,
    catchUpIncomplete: catchUp.incomplete,
  };
}

export function conversationContextText(context: ConversationContext): string {
  const lagNote = context.catchUpIncomplete && context.lagMessageCount > 0
    ? `【注意】今日仍有约 ${context.lagMessageCount} 条消息未完全消化进总览；涉及更早细节时可使用 search_chat_messages。`
    : "";
  return [
    context.dayDigestText ? `【今日聊天总览】\n${context.dayDigestText}` : "【今日聊天总览】暂无（今天可能刚开始或摘要尚未生成）",
    context.yesterdayTitlesText
      ? `【昨日话题标题】（仅标题，无细节；跨天细节用 Memory 或 search_chat_messages）\n${context.yesterdayTitlesText}`
      : "",
    context.recentSegmentsText
      ? `【今日较早时段要点】（已滚出/辅助热窗口的时段摘要）\n${context.recentSegmentsText}`
      : "",
    lagNote,
    context.supplemental.length
      ? `【辅助背景：较早原文，优先级低于重点原文与今日总览】\n${compactLines(context.supplemental)}`
      : "",
    context.focus.length
      ? `【重点上下文：最近 ${CONVERSATION_FOCUS_MESSAGES} 条原文，优先用于指代与语气】\n${compactLines(context.focus)}`
      : "【重点上下文】暂无",
  ].filter(Boolean).join("\n\n");
}
