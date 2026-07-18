// Agent、工具和后台任务共享的生成参数与节奏配置。

import type { AiProvider } from "../config";

export interface GenProfile {
  maxTokens: number;
  temperature: number;
  timeoutMs?: number;
  reasoningEffort?: AiProvider["reasoningEffort"];
}

export const GEN = {
  // 输出预算需覆盖推理+1~3 条短回复；过高会抬计费上限，6000 对闲聊偏浪费。
  reply: { maxTokens: 3500, temperature: 0.85, timeoutMs: 45_000 },
  /** Agent 用满工具轮次后的无工具收尾，只根据已有结果生成最终 JSON */
  replyRecovery: {
    maxTokens: 1200,
    temperature: 0.3,
    timeoutMs: 15_000,
    reasoningEffort: "low",
  },
  extractFacts: {
    maxTokens: 3200,
    temperature: 0.2,
    timeoutMs: 120_000,
    reasoningEffort: "low",
  },
  /** 基础提取遗漏明确里程碑时的单张 event 聚焦复核 */
  eventRecovery: {
    maxTokens: 700,
    temperature: 0.1,
    timeoutMs: 45_000,
    reasoningEffort: "low",
  },
  contextSummary: {
    maxTokens: 700,
    temperature: 0.15,
    timeoutMs: 20_000,
    reasoningEffort: "none",
  },
  /** 将新微段增量合并进日总览；只返回小补丁，不重写整份总览 */
  contextDigest: {
    maxTokens: 800,
    temperature: 0.1,
    timeoutMs: 15_000,
    reasoningEffort: "none",
  },
  /** 公聊冲突/搭话精简分类 */
  engagement: {
    maxTokens: 180,
    temperature: 0.15,
    timeoutMs: 20_000,
    reasoningEffort: "low",
  },
  dailyRecommendation: { maxTokens: 400, temperature: 0.75, timeoutMs: 30_000 },
  /** 大橘日记：约 500 字的诗性手记 */
  diary: { maxTokens: 1_000, temperature: 0.8, timeoutMs: 60_000 },
} satisfies Record<string, GenProfile>;

/**
 * Responses 兼容网关在未声明 summary 时，可能把空 summary 序列化成对象；
 * Agents SDK 期望这里始终是数组并会直接调用 .map()。显式声明 auto
 * 保持原生 Responses/联网能力，同时让网关返回合法的 reasoning item。
 */
export function responsesReasoningSettings(effort: AiProvider["reasoningEffort"]) {
  return effort ? { effort, summary: "auto" as const } : undefined;
}

export const CONTEXT = {
  lineMax: 180,
  /** 热窗口：最近原文中标为重点的条数 */
  recentFocusCount: 16,
  /** 热窗口：最近原文总条数（含重点） */
  recentMaxCount: 40,
  /** 微段：满多少条有效消息压一段 */
  segmentMessageCount: 40,
  /** 微段：至少多少条才允许按空闲/强制压缩 */
  segmentMinMessages: 12,
  /** 微段：最新消息空闲多久后可压（有 min 条时） */
  segmentIdleMs: 10 * 60 * 1000,
  /** 微段：最老未压消息最长等待 */
  segmentMaxAgeMs: 45 * 60 * 1000,
  /** 当日总览渲染进 prompt 的汉字上限 */
  dayDigestMaxChars: 2500,
  /** 当日活跃话题卡上限 */
  dayTopicMax: 24,
  /** prompt 中附带的最近微段数（总览已吸收多数要点，1 段通常够） */
  pendingSegmentPromptMax: 1,
  /** @大橘 前同步追赶预算 */
  catchUpBudgetMs: 25_000,
  /** 追赶分页大小 */
  catchUpPageSize: 80,
  /** 新消息后防抖调度 */
  scheduleDebounceMs: 3_000,
  /** 兼容旧引用：摘要类任务字符上限 */
  summaryMaxChars: 2500,
  taskReminderCount: 20,
  taskMemoCount: 12,
  taskMemoTextMax: 200,
} as const;

export const PACE = {
  replyGapMinMs: 900,
  replyGapJitterMs: 700,
  /** 同频道可串行排队的上限；超出后只保留最新一条（coalesce） */
  queuePendingMax: 5,
  respondTimeoutMs: 120_000,
} as const;

export const DAY_ROLLOVER_HOUR = 6;
