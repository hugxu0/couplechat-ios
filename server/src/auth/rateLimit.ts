// 进程内滑动窗口限流。双人私服足够；生产仍应在边缘 Nginx 叠加 limit_req。

export interface RateLimitResult {
  allowed: boolean;
  retryAfterMs: number;
  remaining: number;
}

interface Bucket {
  hits: number[];
}

const buckets = new Map<string, Bucket>();

function prune(hits: number[], windowMs: number, now: number): number[] {
  const floor = now - windowMs;
  let index = 0;
  while (index < hits.length && hits[index]! < floor) index += 1;
  return index === 0 ? hits : hits.slice(index);
}

export function consumeRateLimit(input: {
  key: string;
  limit: number;
  windowMs: number;
  now?: number;
}): RateLimitResult {
  const now = input.now ?? Date.now();
  const existing = buckets.get(input.key) ?? { hits: [] };
  const hits = prune(existing.hits, input.windowMs, now);
  if (hits.length >= input.limit) {
    const oldest = hits[0] ?? now;
    const retryAfterMs = Math.max(0, oldest + input.windowMs - now);
    buckets.set(input.key, { hits });
    return { allowed: false, retryAfterMs, remaining: 0 };
  }
  hits.push(now);
  buckets.set(input.key, { hits });
  // 防止 Map 无限增长：低频清理空桶。
  if (buckets.size > 5_000) {
    for (const [key, bucket] of buckets) {
      const kept = prune(bucket.hits, input.windowMs, now);
      if (!kept.length) buckets.delete(key);
      else buckets.set(key, { hits: kept });
    }
  }
  return {
    allowed: true,
    retryAfterMs: 0,
    remaining: Math.max(0, input.limit - hits.length),
  };
}

/** 测试或运维可清空。 */
export function resetRateLimits(): void {
  buckets.clear();
}
