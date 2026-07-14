import type { FastifyInstance } from "fastify";
import { requireAuth } from "../auth/httpAuth";
import { backfillDiaryHistory, dailyContent } from "../ai/background/dailyContent";

export async function registerDailyRoutes(app: FastifyInstance) {
  app.get("/api/daily", { preHandler: requireAuth }, async () => {
    // backfill 会在第一次 await 前同步标记为进行中，dailyContent 因而能把
    // 完整加载状态一并返回给客户端，避免客户端看到第一篇就误判完成。
    void backfillDiaryHistory(30);
    return dailyContent();
  });
}
