// 公聊后台介入：日总览 + 微段 + 短原文 → 精简分类 → 可选 Agent。
// 与 Memory 批处理解耦；本地预过滤可跳过明显无价值的模型调用。

import { accounts } from "./accounts";
import { compactLine, recentConversationMessages } from "./conversation/log";
import { chat, extractJson } from "./provider";
import { GEN } from "./settings";
import { readRuntimeState, writeRuntimeState } from "./runtimeState";

export type EngagementKind = "conflict" | "interject";

export interface EngagementSignal {
  channel: "couple";
  kind: EngagementKind;
  confidence: number;
  reason: string;
  topicHint: string;
  requesterUsername: string;
  requesterName: string;
  /** 已压缩背景，供 Agent 复核 */
  context: string;
}

export interface EngagementSegmentInput {
  id: string;
  dayKey: string;
  timeRangeLabel: string;
  endedAt: number;
  messageCount: number;
  bullets: string[];
}

export interface EngagementDigestInput {
  dayKey: string;
  topics: Array<{
    title: string;
    status: string;
    points: string[];
  }>;
  openLoops: string[];
  decisions: string[];
  moodLine: string;
}

type EngagementHandler = (signal: EngagementSignal) => void | Promise<void>;

const COOLDOWNS_MS: Record<EngagementKind, number> = {
  conflict: 15 * 60 * 1000,
  interject: 2 * 60 * 60 * 1000,
};
export const ENGAGEMENT_GLOBAL_COOLDOWN_MS = 5 * 60 * 1000;
export const ENGAGEMENT_CONFLICT_GLOBAL_OVERRIDE = 0.99;
export const ENGAGEMENT_MAX_SEGMENT_AGE_MS = 20 * 60 * 1000;
const THRESHOLDS: Record<EngagementKind, number> = {
  conflict: 0.7,
  interject: 0.78,
};
const RECENT_RAW_LINES = 14;

/** 对立/升级信号（保守：宁可多调模型，不可乱 skip conflict） */
const CONFLICT_RE =
  /吵|骂|滚|分手|冷战|不理我|气死|讨厌你|骗我|恨你|别说话|凭什么|你总是|受不了|分手吧|滚啊|闭嘴|无语|过分|失望|委屈/;
/** 已缓和 */
const CALM_RE = /和好|没事了|没事啦|爱你|么么|晚安|抱抱|原谅|错怪|消气/;
/** 可轻推的未决/安排 */
const INTERJECT_RE =
  /未决|明天|周末|一起|约|订票|订房|买不买|去哪|怎么办|纠结|选哪个|要不要|记得|别忘|提醒/;

let handler: EngagementHandler | null = null;
export interface EngagementCooldownSnapshot extends Partial<Record<EngagementKind, number>> {
  global?: number;
}

export interface EngagementCooldownBlock {
  scope: "kind" | "global";
  remainingMs: number;
}

export function engagementCooldownBlock(
  kind: EngagementKind,
  confidence: number,
  now: number,
  snapshot: EngagementCooldownSnapshot,
): EngagementCooldownBlock | null {
  const kindRemaining = COOLDOWNS_MS[kind] - (now - (snapshot[kind] ?? 0));
  if (kindRemaining > 0) return { scope: "kind", remainingMs: kindRemaining };
  const globalRemaining = ENGAGEMENT_GLOBAL_COOLDOWN_MS - (now - (snapshot.global ?? 0));
  const canOverrideGlobal = kind === "conflict"
    && confidence >= ENGAGEMENT_CONFLICT_GLOBAL_OVERRIDE;
  return globalRemaining > 0 && !canOverrideGlobal
    ? { scope: "global", remainingMs: globalRemaining }
    : null;
}

export function isEngagementSegmentStale(endedAt: number, now: number): boolean {
  return !Number.isFinite(endedAt)
    || endedAt <= 0
    || now - endedAt > ENGAGEMENT_MAX_SEGMENT_AGE_MS;
}

const lastFiredAt: EngagementCooldownSnapshot = {};
const running = new Set<string>();
const COOLDOWN_STATE_KEY = "engagement:cooldown:v1";
let cooldownLoaded = false;

export function setEngagementHandler(next: EngagementHandler | null): void {
  handler = next;
}

async function ensureCooldownLoaded(): Promise<void> {
  if (cooldownLoaded) return;
  cooldownLoaded = true;
  try {
    const raw = await readRuntimeState(COOLDOWN_STATE_KEY);
    if (!raw) return;
    const parsed = JSON.parse(raw) as EngagementCooldownSnapshot;
    if (typeof parsed.conflict === "number") lastFiredAt.conflict = parsed.conflict;
    if (typeof parsed.interject === "number") lastFiredAt.interject = parsed.interject;
    if (typeof parsed.global === "number") lastFiredAt.global = parsed.global;
  } catch {
    // 损坏状态忽略，按内存默认
  }
}

async function persistCooldowns(): Promise<void> {
  await writeRuntimeState(
    COOLDOWN_STATE_KEY,
    JSON.stringify({
      conflict: lastFiredAt.conflict ?? 0,
      interject: lastFiredAt.interject ?? 0,
      global: lastFiredAt.global ?? 0,
    }),
  );
}

function slimDigestText(digest: EngagementDigestInput): string {
  const lines: string[] = [`作息日 ${digest.dayKey}`];
  if (digest.moodLine) lines.push(`情绪：${digest.moodLine}`);
  if (digest.openLoops.length) {
    lines.push(`未决：${digest.openLoops.slice(0, 3).join("；")}`);
  }
  if (digest.decisions.length) {
    lines.push(`决定：${digest.decisions.slice(0, 3).join("；")}`);
  }
  const topics = digest.topics.slice(0, 8);
  if (topics.length) {
    lines.push("话题：");
    for (const topic of topics) {
      const point = topic.points[0] ? ` — ${topic.points[0]}` : "";
      lines.push(`- ${topic.title}（${topic.status}）${point}`);
    }
  }
  return lines.join("\n");
}

function buildAgentContextPack(input: {
  segment: EngagementSegmentInput;
  reason: string;
  topicHint: string;
}): string {
  return [
    `检测线索（不可信）：${input.reason}`,
    input.topicHint ? `话题提示：${input.topicHint}` : "",
    `本段要点 ${input.segment.timeRangeLabel}：`,
    ...input.segment.bullets.map((bullet) => `· ${bullet}`),
  ].filter(Boolean).join("\n");
}

function resolveRequester(recent: Awaited<ReturnType<typeof recentConversationMessages>>) {
  const people = accounts();
  const owner = [...recent].reverse().find(
    (message) => message.kind === "user" && message.sender !== "ai",
  );
  if (owner) {
    return {
      requesterUsername: owner.sender,
      requesterName: owner.senderName || owner.sender,
    };
  }
  const fallback = people[0];
  return {
    requesterUsername: fallback?.username ?? "xu",
    requesterName: fallback?.name ?? "主人",
  };
}

/**
 * 本地预过滤：明显无介入价值则跳过模型。
 * - 只看当前微段与最近原文，避免旧未决/旧情绪让门闩永久打开
 * - 后出现的冲突覆盖更早的缓和；冲突后已明确缓和则跳过
 * - 当前仍有安排/选择信号时才考虑主动搭话
 */
export function localEngagementGate(
  _digest: EngagementDigestInput,
  segment: EngagementSegmentInput,
  recentLines: string[],
): "skip" | "run" {
  const currentText = [
    ...segment.bullets,
    ...recentLines,
  ].join("\n");

  const lastIndex = (pattern: RegExp): number => {
    const flags = pattern.flags.includes("g") ? pattern.flags : `${pattern.flags}g`;
    let found = -1;
    for (const match of currentText.matchAll(new RegExp(pattern.source, flags))) {
      found = match.index ?? found;
    }
    return found;
  };
  const conflictAt = lastIndex(CONFLICT_RE);
  if (conflictAt >= 0) {
    // 只把“冲突之后出现的缓和”视为已解决；旧的爱意/道歉不能掩盖后来的升级。
    return lastIndex(CALM_RE) > conflictAt ? "skip" : "run";
  }
  return INTERJECT_RE.test(currentText) ? "run" : "skip";
}

export function notifyCoupleSegmentCommitted(input: {
  digest: EngagementDigestInput;
  segment: EngagementSegmentInput;
}): void {
  void evaluateCoupleEngagement(input).catch((error) => {
    console.warn(
      `[engagement] decision=error stage=evaluate errorType=` +
        `${error instanceof Error ? error.name : "unknown"}`,
    );
  });
}

async function evaluateCoupleEngagement(input: {
  digest: EngagementDigestInput;
  segment: EngagementSegmentInput;
}): Promise<void> {
  const channel = "couple";
  if (running.has(channel)) {
    console.log("[engagement] decision=skipped_busy");
    return;
  }
  running.add(channel);
  try {
    await ensureCooldownLoaded();
    const segmentAgeMs = Date.now() - input.segment.endedAt;
    if (isEngagementSegmentStale(input.segment.endedAt, Date.now())) {
      console.log(
        `[engagement] decision=skipped_stale segmentAgeMs=${Math.max(0, segmentAgeMs)}`,
      );
      return;
    }
    const recent = await recentConversationMessages(channel, RECENT_RAW_LINES);
    const recentLines = recent
      .map((message) => compactLine(message, 100))
      .filter(Boolean)
      .slice(-RECENT_RAW_LINES);

    const gate = localEngagementGate(input.digest, input.segment, recentLines);
    if (gate === "skip") {
      console.log("[engagement] decision=skipped_local_quiet");
      return;
    }

    const classificationStartedAt = Date.now();
    const output = await chat({
      profile: "task",
      scope: "engagement",
      system:
        '公聊介入分类器，不回复用户。conflict=对立未缓和；interject=无冲突但有轻推价值；闲聊=none。拿不准=none。只输出JSON：{"kind":"none|conflict|interject","confidence":0,"reason":"≤40字","topicHint":""}',
      user: [
        slimDigestText(input.digest),
        `段 ${input.segment.timeRangeLabel}: ${input.segment.bullets.join("；")}`,
        `近文: ${recentLines.join(" / ") || "无"}`,
      ].join("\n"),
      gen: GEN.engagement,
    });
    const classificationDurationMs = Date.now() - classificationStartedAt;
    if (!output) {
      console.warn(
        `[engagement] decision=classifier_unavailable durationMs=${classificationDurationMs}`,
      );
      return;
    }

    const parsed = extractJson<{
      kind?: string;
      confidence?: number;
      reason?: string;
      topicHint?: string;
    }>(output);
    if (!parsed) {
      console.warn(
        `[engagement] decision=invalid_output durationMs=${classificationDurationMs}`,
      );
      return;
    }

    const kindRaw = String(parsed?.kind ?? "none").toLowerCase();
    const kind = kindRaw === "conflict" || kindRaw === "interject" ? kindRaw : "none";
    const confidence = Math.max(0, Math.min(1, Number(parsed?.confidence) || 0));
    const reason = String(parsed?.reason ?? "").replace(/\s+/g, " ").trim().slice(0, 80);
    const topicHint = String(parsed?.topicHint ?? "").replace(/\s+/g, " ").trim().slice(0, 40);

    if (kind === "none") {
      console.log(
        `[engagement] decision=none conf=${confidence.toFixed(2)} ` +
          `durationMs=${classificationDurationMs}`,
      );
      return;
    }

    const threshold = THRESHOLDS[kind];
    if (confidence < threshold) {
      console.log(
        `[engagement] decision=suppressed_threshold kind=${kind} ` +
          `conf=${confidence.toFixed(2)} need=${threshold} durationMs=${classificationDurationMs}`,
      );
      return;
    }

    const now = Date.now();
    const cooldown = engagementCooldownBlock(kind, confidence, now, lastFiredAt);
    if (cooldown) {
      console.log(
        `[engagement] decision=suppressed_cooldown kind=${kind} ` +
          `scope=${cooldown.scope} conf=${confidence.toFixed(2)} ` +
          `cdLeftMs=${cooldown.remainingMs} durationMs=${classificationDurationMs}`,
      );
      return;
    }

    if (!handler) {
      console.log(
        `[engagement] decision=no_handler kind=${kind} ` +
          `conf=${confidence.toFixed(2)} durationMs=${classificationDurationMs}`,
      );
      return;
    }

    const requester = resolveRequester(recent);
    const signal: EngagementSignal = {
      channel: "couple",
      kind,
      confidence,
      reason,
      topicHint,
      requesterUsername: requester.requesterUsername,
      requesterName: requester.requesterName,
      context: buildAgentContextPack({
        segment: input.segment,
        reason,
        topicHint,
      }),
    };

    lastFiredAt[kind] = now;
    lastFiredAt.global = now;
    await persistCooldowns().catch(() => undefined);
    console.log(
      `[engagement] decision=emit kind=${kind} conf=${confidence.toFixed(2)} ` +
        `durationMs=${classificationDurationMs}`,
    );

    // 高置信冲突时顺带刷新关系卡，供后续 Agent 只读工具更准（不阻塞开口）。
    if (kind === "conflict" && confidence >= 0.8) {
      void import("./memory/derived").then(({ refreshDerivedMemory }) =>
        refreshDerivedMemory("couple", { forceRelationship: true }),
      ).catch(() => undefined);
    }

    await Promise.resolve(handler(signal));
  } finally {
    running.delete(channel);
  }
}
