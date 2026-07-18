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
const lastFiredAt: Partial<Record<EngagementKind, number>> = {};
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
    const parsed = JSON.parse(raw) as Partial<Record<EngagementKind, number>>;
    if (typeof parsed.conflict === "number") lastFiredAt.conflict = parsed.conflict;
    if (typeof parsed.interject === "number") lastFiredAt.interject = parsed.interject;
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
 * - 有冲突词且未缓和 → 必须过模型
 * - 有未决/安排信号 → 过模型
 * - 总览情绪含争/吵 → 过模型
 * - 其余 skip
 */
export function localEngagementGate(
  digest: EngagementDigestInput,
  segment: EngagementSegmentInput,
  recentLines: string[],
): "skip" | "run" {
  const haystack = [
    digest.moodLine,
    ...digest.openLoops,
    ...digest.topics.flatMap((topic) => [topic.title, ...topic.points.slice(0, 2)]),
    ...segment.bullets,
    ...recentLines,
  ].join("\n");

  const calmed = CALM_RE.test(haystack);
  const conflictish = CONFLICT_RE.test(haystack) || /争|吵|冷战|疏离/.test(digest.moodLine);
  if (conflictish && !calmed) return "run";
  if (digest.openLoops.length > 0) return "run";
  if (INTERJECT_RE.test(haystack)) return "run";
  if (segment.bullets.some((bullet) => CONFLICT_RE.test(bullet) || INTERJECT_RE.test(bullet))) {
    return "run";
  }
  return "skip";
}

export function notifyCoupleSegmentCommitted(input: {
  digest: EngagementDigestInput;
  segment: EngagementSegmentInput;
}): void {
  void evaluateCoupleEngagement(input).catch((error) => {
    console.warn(
      "[engagement] 分类失败:",
      error instanceof Error ? error.message : error,
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

    const parsed = extractJson<{
      kind?: string;
      confidence?: number;
      reason?: string;
      topicHint?: string;
    }>(output);

    const kindRaw = String(parsed?.kind ?? "none").toLowerCase();
    const kind = kindRaw === "conflict" || kindRaw === "interject" ? kindRaw : "none";
    const confidence = Math.max(0, Math.min(1, Number(parsed?.confidence) || 0));
    const reason = String(parsed?.reason ?? "").replace(/\s+/g, " ").trim().slice(0, 80);
    const topicHint = String(parsed?.topicHint ?? "").replace(/\s+/g, " ").trim().slice(0, 40);

    if (kind === "none") {
      console.log(
        `[engagement] decision=none conf=${confidence.toFixed(2)} reason=${reason || "—"}`,
      );
      return;
    }

    const threshold = THRESHOLDS[kind];
    if (confidence < threshold) {
      console.log(
        `[engagement] decision=suppressed_threshold kind=${kind} conf=${confidence.toFixed(2)} need>=${threshold} reason=${reason || "—"}`,
      );
      return;
    }

    const now = Date.now();
    const lastAt = lastFiredAt[kind] ?? 0;
    const coolLeft = COOLDOWNS_MS[kind] - (now - lastAt);
    if (coolLeft > 0) {
      console.log(
        `[engagement] decision=suppressed_cooldown kind=${kind} conf=${confidence.toFixed(2)} cdLeft=${Math.ceil(coolLeft / 60000)}m reason=${reason || "—"}`,
      );
      return;
    }

    if (!handler) {
      console.log(`[engagement] decision=no_handler kind=${kind} conf=${confidence.toFixed(2)}`);
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
    await persistCooldowns().catch(() => undefined);
    console.log(
      `[engagement] decision=emit kind=${kind} conf=${confidence.toFixed(2)} topic=${topicHint || "—"} reason=${reason || "—"}`,
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
