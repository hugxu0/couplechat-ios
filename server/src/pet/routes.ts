import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "../auth/httpAuth";
import { getPet, interactPet } from "./service";

const interactionBody = z.object({
  kind: z.enum(["feed", "bathe", "play", "stroke", "sleep"]),
  idempotencyKey: z.string().min(1).max(128),
  baseVersion: z.number().int().min(0),
});

function mutationReply(reply: any, result: any) {
  if (!result) return reply.code(409).send({ error: "couple_required" });
  if (result.idempotencyConflict) return reply.code(409).send({ error: "idempotency_conflict" });
  if (result.conflict) return reply.code(409).send({ error: "version_conflict", pet: result.pet });
  if (result.cooldown) {
    return reply.code(429).send({
      error: "pet_interaction_cooldown",
      availableAt: result.availableAt,
      pet: result.pet,
    });
  }
  return { pet: result.pet };
}

export async function registerPetRoutes(app: FastifyInstance) {
  app.get("/api/v2/pet", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const result = await getPet(request.user);
    return result ?? reply.code(409).send({ error: "couple_required" });
  });

  app.post("/api/v2/pet/interactions", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const body = interactionBody.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: "invalid_request" });
    return mutationReply(reply, await interactPet(request.user, body.data));
  });

}
