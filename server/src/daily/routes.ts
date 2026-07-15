import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "../auth/httpAuth";
import {
  createMemberRecommendation,
  hideRecommendation,
  readThroughRecommendation,
  recommendationHistory,
  refreshTodayRecommendation,
  todayRecommendations,
  unreadRecommendationCount,
} from "./recommendationService";

const contentBody = z.object({ content: z.string().trim().min(1).max(500) });
const idParams = z.object({ recommendationId: z.string().min(1).max(128) });
const historyQuery = z.object({
  cursor: z.string().max(500).optional(),
  limit: z.coerce.number().int().min(1).max(100).default(30),
});

export async function registerRecommendationRoutes(app: FastifyInstance) {
  app.get("/api/v2/recommendations/today", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const result = await todayRecommendations(request.user);
    return result ?? reply.code(409).send({ error: "couple_required" });
  });

  app.get("/api/v2/recommendations/unread-count", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    return { unreadCount: await unreadRecommendationCount(request.user) };
  });

  app.post("/api/v2/recommendations/refresh", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const recommendation = await refreshTodayRecommendation(request.user);
    return recommendation
      ? reply.code(201).send({ recommendation })
      : reply.code(409).send({ error: "couple_required" });
  });

  app.post("/api/v2/recommendations", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const body = contentBody.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: "invalid_request" });
    const recommendation = await createMemberRecommendation(request.user, body.data.content);
    return recommendation
      ? reply.code(201).send({ recommendation })
      : reply.code(409).send({ error: "couple_required" });
  });

  app.get("/api/v2/recommendations/history", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const query = historyQuery.safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await recommendationHistory(request.user, query.data.cursor, query.data.limit);
    return result ?? reply.code(409).send({ error: "couple_required" });
  });

  app.post("/api/v2/recommendations/:recommendationId/read", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: "invalid_request" });
    return await readThroughRecommendation(request.user, params.data.recommendationId)
      ? { ok: true }
      : reply.code(404).send({ error: "not_found" });
  });

  app.delete("/api/v2/recommendations/:recommendationId", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: "invalid_request" });
    return await hideRecommendation(request.user, params.data.recommendationId)
      ? { ok: true }
      : reply.code(404).send({ error: "not_found" });
  });
}
