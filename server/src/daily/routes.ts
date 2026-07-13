import type { FastifyInstance } from "fastify";
import { requireAuth } from "../auth/httpAuth";
import { backfillDiaryHistory, dailyContent, ensureRecommendation } from "../ai/background/dailyContent";
import { cycleDate } from "../ai/time";

export async function registerDailyRoutes(app: FastifyInstance) {
  app.get("/api/daily", { preHandler: requireAuth }, async () => {
    void backfillDiaryHistory(30);
    return dailyContent();
  });

  app.post("/api/daily/recommend", { preHandler: requireAuth }, async () => {
    const recommendation = await ensureRecommendation(cycleDate(), true);
    return { recommend: recommendation };
  });
}
