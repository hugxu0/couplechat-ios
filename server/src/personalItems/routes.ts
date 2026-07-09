import type { FastifyInstance } from "fastify";
import type { Server } from "socket.io";
import { z } from "zod";
import { socketEvents } from "../contracts/realtime";
import { requireAuth } from "../auth/httpAuth";
import {
  createPersonalItem,
  deletePersonalItem,
  listPersonalItems,
  updatePersonalItem,
  type PersonalItemScope,
} from "./itemService";

let io: Server | null = null;

export function setSocketIO(socketServer: Server) {
  io = socketServer;
}

function broadcastSharedChange(action: string, item: unknown) {
  if (!io) return;
  const it = item as { scope?: string } | null;
  if (!it || it.scope !== "shared") return;
  io.to("channel:couple").emit(socketEvents.personalItemChanged, { action, item });
}

const kindSchema = z.enum(["reminder", "memo"]);
const scopeSchema = z.enum(["personal", "shared"]);

const querySchema = z.object({
  kind: kindSchema.optional(),
  scope: scopeSchema.optional(),
});

const createBody = z.object({
  kind: kindSchema,
  scope: scopeSchema.optional(),
  title: z.string().trim().min(1).max(160),
  bodyMarkdown: z.string().max(20000).optional(),
  dueAt: z.number().int().positive().nullable().optional(),
  isDone: z.boolean().optional(),
});

const updateBody = z.object({
  title: z.string().trim().min(1).max(160).optional(),
  bodyMarkdown: z.string().max(20000).optional(),
  dueAt: z.number().int().positive().nullable().optional(),
  isDone: z.boolean().optional(),
});

const paramsSchema = z.object({
  id: z.string().min(1),
});

export async function registerPersonalItemRoutes(app: FastifyInstance) {
  app.get("/api/me/items", { preHandler: requireAuth }, async (request, reply) => {
    const parsed = querySchema.safeParse(request.query);
    if (!parsed.success || !request.user) return reply.code(400).send({ error: "invalid_request" });
    return {
      items: await listPersonalItems(request.user, parsed.data.kind, parsed.data.scope),
    };
  });

  app.post("/api/me/items", { preHandler: requireAuth }, async (request, reply) => {
    const parsed = createBody.safeParse(request.body);
    if (!parsed.success || !request.user) return reply.code(400).send({ error: "invalid_request" });
    const item = await createPersonalItem(request.user, parsed.data);
    broadcastSharedChange("created", item);
    return reply.code(201).send({ item });
  });

  app.patch("/api/me/items/:id", { preHandler: requireAuth }, async (request, reply) => {
    const params = paramsSchema.safeParse(request.params);
    const body = updateBody.safeParse(request.body);
    if (!params.success || !body.success || !request.user) {
      return reply.code(400).send({ error: "invalid_request" });
    }

    const item = await updatePersonalItem(request.user, params.data.id, body.data);
    if (!item) return reply.code(404).send({ error: "not_found" });
    broadcastSharedChange("updated", item);
    return { item };
  });

  app.delete("/api/me/items/:id", { preHandler: requireAuth }, async (request, reply) => {
    const params = paramsSchema.safeParse(request.params);
    if (!params.success || !request.user) return reply.code(400).send({ error: "invalid_request" });

    const ok = await deletePersonalItem(request.user, params.data.id);
    if (!ok) return reply.code(404).send({ error: "not_found" });
    broadcastSharedChange("deleted", { id: params.data.id });
    return { ok: true };
  });
}
