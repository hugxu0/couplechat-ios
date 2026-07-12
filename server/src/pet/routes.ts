import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "../auth/httpAuth";
import { getPet, interactPet, renamePet, respondToday, updatePetScene } from "./service";

const responseBody = z.object({
  promptId: z.string().min(1).max(128),
  text: z.string().trim().min(1).max(1_000),
  idempotencyKey: z.string().min(1).max(128),
  baseVersion: z.number().int().min(0),
});
const interactionBody = z.object({
  kind: z.enum(["stroke", "high_five", "teaser"]),
  idempotencyKey: z.string().min(1).max(128),
  baseVersion: z.number().int().min(0),
});
const sceneBody = z.object({
  placedItemIds: z.array(z.string().min(1).max(128)).max(20),
  baseVersion: z.number().int().min(0),
});
const nameBody = z.object({ name: z.string().trim().min(1).max(24), baseVersion: z.number().int().min(0) });

function mutationReply(reply: any, result: any) {
  if (!result) return reply.code(409).send({ error: "couple_required" });
  if (result.idempotencyConflict) return reply.code(409).send({ error: "idempotency_conflict" });
  if (result.alreadyResponded) return reply.code(409).send({ error: "already_responded" });
  if (result.invalidItems) return reply.code(400).send({ error: "invalid_scene_items" });
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

  app.get("/api/v2/pet/today", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const result = await getPet(request.user);
    return result ? { pet: result.pet, today: result.pet.today } : reply.code(409).send({ error: "couple_required" });
  });

  app.post("/api/v2/pet/today/responses", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const body = responseBody.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: "invalid_request" });
    return mutationReply(reply, await respondToday(request.user, body.data));
  });

  app.post("/api/v2/pet/interactions", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const body = interactionBody.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: "invalid_request" });
    return mutationReply(reply, await interactPet(request.user, body.data));
  });

  app.patch("/api/v2/pet/scene", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const body = sceneBody.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: "invalid_request" });
    return mutationReply(reply, await updatePetScene(request.user, body.data.placedItemIds, body.data.baseVersion));
  });

  app.patch("/api/v2/pet/name", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const body = nameBody.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: "invalid_request" });
    return mutationReply(reply, await renamePet(request.user, body.data.name, body.data.baseVersion));
  });
}
