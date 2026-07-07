// 聊天统计 + 每日内容（大橘日记 / 今日推荐）REST 接口。

import type { FastifyInstance } from "fastify";
import { all } from "../db";
import { requireAuth } from "../auth/httpAuth";
import { dailyContent, ensureRecommendation } from "../ai/dailyContent";
import { cycleDate } from "../ai/time";

interface CountRow {
  sender: string;
  bucket: string;
  c: number;
}

// couple 频道真人消息按北京时间自然日/自然月聚合（大橘和系统消息不计入）。
// format: "YYYY-MM-DD"（日）或 "YYYY-MM"（月），PostgreSQL to_char 格式。
async function countsBy(format: string, sinceTs: number): Promise<CountRow[]> {
  return all<CountRow>(
    `SELECT sender, to_char(to_timestamp(ts / 1000.0) AT TIME ZONE 'UTC' + interval '8 hours', '${format}') AS bucket, COUNT(*) AS c
     FROM messages
     WHERE channel = 'couple' AND kind = 'user' AND sender != 'ai' AND ts >= ?
     GROUP BY sender, bucket`,
    [sinceTs],
  );
}

function group(rows: CountRow[]): Map<string, Record<string, number>> {
  const map = new Map<string, Record<string, number>>();
  for (const row of rows) {
    const bucket = map.get(row.bucket) ?? {};
    bucket[row.sender] = row.c;
    map.set(row.bucket, bucket);
  }
  return map;
}

const WEEKDAYS = ["日", "一", "二", "三", "四", "五", "六"];

export async function registerStatsRoutes(app: FastifyInstance) {
  app.get("/api/stats", { preHandler: requireAuth }, async () => {
    const now = Date.now();
    const dayMs = 24 * 60 * 60 * 1000;

    // 近 10 个自然日
    const daily = group(await countsBy("YYYY-MM-DD", now - 11 * dayMs));
    const days: Array<{ date: string; weekday: string; counts: Record<string, number> }> = [];
    for (let i = 9; i >= 0; i -= 1) {
      const d = new Date(now + 8 * 60 * 60 * 1000 - i * dayMs);
      const key = d.toISOString().slice(0, 10);
      days.push({
        date: key,
        weekday: i === 0 ? "今" : WEEKDAYS[d.getUTCDay()],
        counts: daily.get(key) ?? {},
      });
    }

    // 近 12 个自然月
    const monthly = group(await countsBy("YYYY-MM", now - 370 * dayMs));
    const months: Array<{ month: string; counts: Record<string, number> }> = [];
    const nowBj = new Date(now + 8 * 60 * 60 * 1000);
    for (let i = 11; i >= 0; i -= 1) {
      const d = new Date(Date.UTC(nowBj.getUTCFullYear(), nowBj.getUTCMonth() - i, 1));
      const key = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
      months.push({ month: key, counts: monthly.get(key) ?? {} });
    }

    return { days, months };
  });

  // 每日内容：大橘日记（最近一篇）+ 今日推荐。
  app.get("/api/daily", { preHandler: requireAuth }, async () => dailyContent());

  // 「换一个」：强制重新生成今日推荐。
  app.post("/api/daily/recommend", { preHandler: requireAuth }, async () => {
    const rec = await ensureRecommendation(cycleDate(), true);
    return { recommend: rec };
  });
}
