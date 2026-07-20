import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "../auth/httpAuth";
import { drawCard, getCardGame, useCard } from "./service";

const raritySchema = z.enum(["common", "rare", "epic", "legendary"]);

const drawBody = z.object({
  idempotencyKey: z.string().trim().min(8).max(128),
});

const useBody = z.object({
  cardKey: z.string().trim().min(1).max(80),
  rarity: raritySchema,
  idempotencyKey: z.string().trim().min(8).max(128),
  effectId: z.string().trim().min(1).max(80).optional(),
  sourceCardKey: z.string().trim().min(1).max(80).optional(),
  sourceRarity: raritySchema.optional(),
});

function statusFor(error: string): number {
  switch (error) {
  case "couple_required": return 409;
  case "draw_limit_reached": return 429;
  case "card_not_found": return 404;
  case "card_not_owned":
  case "source_card_not_found":
  case "effect_required":
  case "effect_not_active":
  case "effect_not_owned":
  case "invalid_card_action":
    return 409;
  default: return 400;
  }
}

export async function registerCardGameRoutes(app: FastifyInstance) {
  app.get("/api/v2/card-game", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const result = await getCardGame(request.user);
    if (!result.ok) return reply.code(statusFor(result.error)).send({ error: result.error });
    return { ok: true, game: result.value };
  });

  app.post("/api/v2/card-game/draw", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const parsed = drawBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await drawCard(request.user, parsed.data.idempotencyKey);
    if (!result.ok) return reply.code(statusFor(result.error)).send({ error: result.error });
    return { ok: true, game: result.value.snapshot, draw: result.value.draw };
  });

  app.post("/api/v2/card-game/use", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const parsed = useBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await useCard(request.user, parsed.data);
    if (!result.ok) return reply.code(statusFor(result.error)).send({ error: result.error });
    return { ok: true, game: result.value.snapshot, effect: result.value.effect };
  });
}
