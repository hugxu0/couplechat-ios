// 大橘 AI 的调参中心：maxTokens / temperature / 阈值 / 超时 / 节奏全在这里。
// （沿袭旧后端 aiParams.js 的「单点可调」思路，但只保留新架构真正用到的项。）

export interface GenProfile {
  maxTokens: number;
  temperature: number;
  timeoutMs?: number;
}

export const GEN = {
  // 用户问答：一轮直出 replies JSON（旧版 plan+retrievalQuery+ask 三连已合并）。
  reply: { maxTokens: 2000, temperature: 0.85, timeoutMs: 45_000 },
  // 后台事实提取：只输出 JSON，温度低。
  extractFacts: { maxTokens: 900, temperature: 0.2, timeoutMs: 30_000 },
  // 会话滚动摘要。
  sessionSummary: { maxTokens: 900, temperature: 0.3, timeoutMs: 20_000 },
  // 每日日记（给记忆整理当素材，不展示给用户）。
  dailyDigest: { maxTokens: 2200, temperature: 0.45, timeoutMs: 90_000 },
  // 事件卡片切分。
  episodes: { maxTokens: 4000, temperature: 0.35, timeoutMs: 120_000 },
  // 夜间事实收口（keep/merge/discard 批量裁决）。
  consolidateFacts: { maxTokens: 2000, temperature: 0.2, timeoutMs: 90_000 },
  // 短期记忆重写（近一周叙事，常驻问答上下文）。
  shortTermRewrite: { maxTokens: 3400, temperature: 0.35, timeoutMs: 90_000 },
  // 人物卡 ×2 + 关系卡。
  profileCards: { maxTokens: 1600, temperature: 0.4, timeoutMs: 90_000 },
  // 今日心情一句话。
  dailyMood: { maxTokens: 200, temperature: 0.9, timeoutMs: 20_000 },
} satisfies Record<string, GenProfile>;

export const MEMORY = {
  // 事实检索：注入上限与相似度阈值（低于阈值一条不带，token 只在真相关时花）。
  factTopK: 8,
  factMinScore: Number(process.env.EMBEDDING_FACT_MIN_SCORE) || 0.45,
  // 事件卡片检索。
  episodeTopK: 6,
  episodeMinScore: Number(process.env.EMBEDDING_EPISODE_MIN_SCORE) || 0.4,
  // 新事实入库查重：相似度 ≥ 此值视为重复，只刷新 last_seen_at。
  factDupScore: 0.9,
  // 事实正文长度限制。
  factTextMin: 3,
  factTextMax: 200,
  // 高重要度事实（无 embedding 时的兜底注入 / 人物卡素材）。
  importantFactMin: 4,
  importantFactLimit: 40,
  // 短期记忆注入截断。
  shortTermMax: 4200,
} as const;

export const CONTEXT = {
  // 应答时带多少条最近聊天；最后 immediateCount 条标为「紧邻上文」重点看。
  recentCount: 30,
  immediateCount: 8,
  // 检索查询词：当前问题 + 最近几条用户消息拼接（不再用 LLM 单独生成检索词）。
  retrievalRecentUserLines: 3,
  // 会话滚动摘要。
  sessionSummaryUpdateEvery: 14,
  sessionSummaryMaxChars: 1000,
  sessionSummaryBacklogMax: 200,
  // 单条消息压缩行的截断长度。
  lineMax: 180,
} as const;

export const PACE = {
  // 多条回复之间的拟人停顿（毫秒）。
  replyGapMinMs: 900,
  replyGapJitterMs: 700,
  // 每个频道的应答队列：积压超过此数直接丢弃新触发（多半是连环催）。
  queuePendingMax: 3,
  // 单轮应答兜底超时：超时释放队列，避免后续消息全部堵住。
  respondTimeoutMs: 120_000,
  // 每积累多少条 couple 用户消息触发一次事实提取。
  factScanEveryMessages: 8,
} as const;

// 作息日：北京时间早 6 点切日——半夜聊天算「昨天」，符合两人的真实作息。
export const DAY_ROLLOVER_HOUR = 6;
