// Agent、工具和后台任务共享的生成参数与节奏配置。

export interface GenProfile {
  maxTokens: number;
  temperature: number;
  timeoutMs?: number;
}

export const GEN = {
  // Responses 的输出预算同时承载推理与最终文本；high reasoning 下给普通回复保留足够余量。
  reply: { maxTokens: 6000, temperature: 0.85, timeoutMs: 45_000 },
  extractFacts: { maxTokens: 4000, temperature: 0.2, timeoutMs: 60_000 },
  contextSummary: { maxTokens: 1200, temperature: 0.2, timeoutMs: 30_000 },
  describeImage: { maxTokens: 1500, temperature: 0.4, timeoutMs: 40_000 },
  search: { maxTokens: 1800, temperature: 0.3, timeoutMs: 45_000 },
  conflict: { maxTokens: 1400, temperature: 0.25, timeoutMs: 30_000 },
  interject: { maxTokens: 900, temperature: 0.8, timeoutMs: 20_000 },
  dailyRecommendation: { maxTokens: 500, temperature: 0.75, timeoutMs: 30_000 },
} satisfies Record<string, GenProfile>;

export const CONTEXT = {
  lineMax: 180,
  recentFocusCount: 8,
  recentMaxCount: 50,
  summaryTriggerCount: 50,
  summaryMaxChars: 1800,
  taskReminderCount: 20,
  taskMemoCount: 12,
  taskMemoTextMax: 200,
} as const;

export const PACE = {
  replyGapMinMs: 900,
  replyGapJitterMs: 700,
  queuePendingMax: 3,
  respondTimeoutMs: 120_000,
} as const;

export const DAY_ROLLOVER_HOUR = 6;
