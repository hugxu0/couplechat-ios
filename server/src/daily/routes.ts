import type { FastifyInstance } from "fastify";
import { requireAuth } from "../auth/httpAuth";
import { backfillDiaryHistory, dailyContent } from "../ai/background/dailyContent";

export async function registerDailyRoutes(app: FastifyInstance) {
  app.get("/api/daily", { preHandler: requireAuth }, async () => {
    void backfillDiaryHistory(30);
    return dailyContent();
  });
}
