import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "../../auth/httpAuth";
import { errorCodes } from "../../errors/errorCodes";
import { ensureDiaryForDay, ensureYesterdayDiary, getDiary, listDiaries } from "./service";

const dayKeySchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);

export async function registerDiaryRoutes(app: FastifyInstance) {
  app.get("/api/v2/ai/diaries", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: errorCodes.unauthorized });
    const query = z.object({
      limit: z.coerce.number().int().min(1).max(90).default(30),
    }).safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: errorCodes.invalidRequest });
    const list = await listDiaries(query.data.limit);
    return { ok: true, list };
  });

  app.get("/api/v2/ai/diaries/:dayKey", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: errorCodes.unauthorized });
    const params = z.object({ dayKey: dayKeySchema }).safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: errorCodes.invalidRequest });
    const diary = await getDiary(params.data.dayKey);
    if (!diary) return reply.code(404).send({ error: errorCodes.notFound });
    return { ok: true, diary };
  });

  // 调试/补生成：确保某日或昨日日记（只写 couple 材料）。
  app.post("/api/v2/ai/diaries/ensure", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: errorCodes.unauthorized });
    const body = z.object({
      dayKey: dayKeySchema.optional(),
      force: z.boolean().optional(),
    }).safeParse(request.body ?? {});
    if (!body.success) return reply.code(400).send({ error: errorCodes.invalidRequest });
    const diary = body.data.dayKey
      ? await ensureDiaryForDay(body.data.dayKey, { force: body.data.force })
      : await ensureYesterdayDiary(Date.now(), { force: body.data.force });
    if (!diary) return reply.code(404).send({ error: errorCodes.notFound, reason: "empty_or_unavailable" });
    return { ok: true, diary };
  });
}
