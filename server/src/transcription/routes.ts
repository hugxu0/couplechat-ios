import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "../auth/httpAuth";
import { correctTranscript, getTranscript, retryTranscript } from "./service";

const paramsSchema = z.object({ messageId: z.string().min(1).max(128) });
const correctionSchema = z.object({
  text: z.string().trim().min(1).max(20_000),
  baseVersion: z.number().int().min(0).optional(),
});

export async function registerTranscriptionRoutes(app: FastifyInstance) {
  app.get("/api/v2/messages/:messageId/transcript", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = paramsSchema.safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: "invalid_request" });
    const transcript = await getTranscript(request.user, params.data.messageId);
    return transcript ? { transcript } : reply.code(404).send({ error: "not_found" });
  });

  app.post("/api/v2/messages/:messageId/transcript/retry", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = paramsSchema.safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await retryTranscript(request.user, params.data.messageId);
    if (!result) return reply.code(404).send({ error: "not_found" });
    if (result.unavailable) {
      return { transcript: result.transcript };
    }
    return { transcript: result.transcript };
  });

  app.patch("/api/v2/messages/:messageId/transcript", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = paramsSchema.safeParse(request.params);
    const body = correctionSchema.safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await correctTranscript(
      request.user,
      params.data.messageId,
      body.data.text,
      body.data.baseVersion,
    );
    if (!result) return reply.code(404).send({ error: "not_found" });
    if (result.conflict) return reply.code(409).send({ error: "version_conflict", transcript: result.transcript });
    return { transcript: result.transcript };
  });
}
