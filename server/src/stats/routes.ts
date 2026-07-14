import type { FastifyInstance } from "fastify";
import { requireAuth } from "../auth/httpAuth";
import { all } from "../db";

interface CountRow {
  bucket: string;
  sender: string;
  count: number;
}

export async function registerStatsRoutes(app: FastifyInstance) {
  app.get("/api/v2/chat/stats", { preHandler: requireAuth }, async () => {
    const days = await all<CountRow>(
      `SELECT to_char(to_timestamp(ts / 1000.0) AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD') AS bucket,
              sender, COUNT(*)::int AS count
       FROM messages
       WHERE channel = 'couple' AND kind = 'user' AND sender <> 'ai'
         AND ts >= ?
       GROUP BY bucket, sender
       ORDER BY bucket ASC`,
      [Date.now() - 35 * 24 * 60 * 60 * 1000],
    );
    const months = await all<CountRow>(
      `SELECT to_char(to_timestamp(ts / 1000.0) AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM') AS bucket,
              sender, COUNT(*)::int AS count
       FROM messages
       WHERE channel = 'couple' AND kind = 'user' AND sender <> 'ai'
       GROUP BY bucket, sender
       ORDER BY bucket ASC`,
    );
    return { days, months };
  });
}
