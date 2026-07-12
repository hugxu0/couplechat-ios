// Agent、工具和后台任务共享的生成参数与节奏配置。

export interface GenProfile {
  maxTokens: number;
  temperature: number;
  timeoutMs?: number;
}

export const GEN = {
  reply: { maxTokens: 2000, temperature: 0.85, timeoutMs: 45_000 },
  extractFacts: { maxTokens: 4000, temperature: 0.2, timeoutMs: 60_000 },
  contextSummary: { maxTokens: 700, temperature: 0.2, timeoutMs: 20_000 },
  describeImage: { maxTokens: 1500, temperature: 0.4, timeoutMs: 40_000 },
  search: { maxTokens: 1800, temperature: 0.3, timeoutMs: 45_000 },
  conflict: { maxTokens: 1400, temperature: 0.25, timeoutMs: 30_000 },
  interject: { maxTokens: 900, temperature: 0.8, timeoutMs: 20_000 },
} satisfies Record<string, GenProfile>;

export const CONTEXT = {
  lineMax: 180,
  recentCount: 14,
  summaryUpdateEvery: 12,
  summaryBacklogMax: 160,
  summaryMaxChars: 900,
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
