import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "../../auth/httpAuth";
import { flushMemory } from "./extractor";
import {
  MEMORY_LAYERS,
  deleteMemoryForControl,
  getMemoryForControl,
  listMemoryForControl,
  memorySources,
  memoryStatsForScopes,
  updateMemoryForControl,
  type MemoryLayer,
} from "./store";
import { activeIdentity } from "../../auth/identity";
import { decodeCursor, encodeCursor } from "../../utils/cursor";

const listQuery = z.object({
  scope: z.enum(["all", "shared", "private"]).default("all"),
  layer: z.string().optional(),
  status: z.enum(["active", "all"]).default("active"),
  subject: z.enum(["xu", "si", "both"]).optional(),
  q: z.string().max(120).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(100),
  cursor: z.string().max(240).optional(),
});

const updateBody = z.object({
  content: z.string().trim().min(3).max(1200),
  importance: z.number().int().min(1).max(5).optional(),
  baseVersion: z.number().int().min(0).optional(),
});

const refreshBody = z.object({
  scope: z.enum(["shared", "private"]),
});

function visibleScopes(username: string): string[] {
  return ["couple", `ai:${username}`];
}

function filteredScopes(username: string, scope: "all" | "shared" | "private"): string[] {
  if (scope === "shared") return ["couple"];
  if (scope === "private") return [`ai:${username}`];
  return visibleScopes(username);
}

function isMemoryCursor(value: unknown): value is { updatedAt: number; id: string } {
  if (!value || typeof value !== "object") return false;
  const cursor = value as Record<string, unknown>;
  return typeof cursor.updatedAt === "number"
    && Number.isFinite(cursor.updatedAt)
    && typeof cursor.id === "string";
}

export async function registerMemoryRoutes(app: FastifyInstance) {
  app.get("/api/me/memory", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const identity = await activeIdentity(request.user);
    if (!identity) return reply.code(401).send({ error: "unauthorized" });
    const parsed = listQuery.safeParse(request.query);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    const layer = MEMORY_LAYERS.includes(parsed.data.layer as MemoryLayer)
      ? parsed.data.layer as MemoryLayer
      : undefined;
    const scopes = filteredScopes(request.user.username, parsed.data.scope)
      .filter((scope) => scope !== "couple" || Boolean(identity.coupleId));
    const [page, stats] = await Promise.all([
      listMemoryForControl({
        scopes,
        coupleId: identity.coupleId,
        accountId: identity.accountId,
        layer,
        status: parsed.data.status === "all" ? undefined : parsed.data.status,
        subject: parsed.data.subject,
        query: parsed.data.q,
        limit: parsed.data.limit + 1,
        cursor: decodeCursor(parsed.data.cursor, isMemoryCursor) ?? undefined,
      }),
      memoryStatsForScopes(visibleScopes(request.user.username), identity),
    ]);
    const items = page.slice(0, parsed.data.limit);
    const hasMore = page.length > parsed.data.limit;
    return {
      ok: true,
      scope: parsed.data.scope,
      items,
      stats,
      hasMore,
      nextCursor: hasMore && items.length
        ? encodeCursor({ updatedAt: items.at(-1)!.updatedAt, id: items.at(-1)!.id })
        : null,
    };
  });

  app.get<{ Params: { id: string } }>(
    "/api/me/memory/:id/evidence",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      const identity = await activeIdentity(request.user);
      if (!identity) return reply.code(401).send({ error: "unauthorized" });
      // 兼容尚未升级的旧客户端；新系统不再保存或返回原始消息证据。
      return { ok: true, evidence: [] };
    },
  );

  app.get<{ Params: { id: string } }>(
    "/api/me/memory/:id/sources",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      const identity = await activeIdentity(request.user);
      if (!identity) return reply.code(401).send({ error: "unauthorized" });
      const sources = await memorySources(
        request.params.id, visibleScopes(request.user.username), identity);
      return { ok: true, sources };
    },
  );

  app.patch<{ Params: { id: string } }>(
    "/api/me/memory/:id",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      const identity = await activeIdentity(request.user);
      if (!identity) return reply.code(401).send({ error: "unauthorized" });
      const parsed = updateBody.safeParse(request.body);
      if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
      let item;
      try {
        item = await updateMemoryForControl({
          memoryId: request.params.id,
          scopes: visibleScopes(request.user.username),
          coupleId: identity.coupleId,
          accountId: identity.accountId,
          content: parsed.data.content,
          importance: parsed.data.importance,
          editor: request.user.username,
          editorAccountId: identity.accountId,
          editorDeviceId: request.user.deviceId,
          baseVersion: parsed.data.baseVersion,
        });
      } catch (error) {
        if (error instanceof Error && error.message === "memory_version_conflict") {
          const current = await getMemoryForControl(request.params.id, {
            scopes: visibleScopes(request.user.username),
            coupleId: identity.coupleId,
            accountId: identity.accountId,
          });
          return reply.code(409).send({ error: "memory_version_conflict", item: current });
        }
        throw error;
      }
      if (!item) return reply.code(404).send({ error: "memory_not_found" });
      return { ok: true, item };
    },
  );

  app.delete<{ Params: { id: string } }>(
    "/api/me/memory/:id",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      const identity = await activeIdentity(request.user);
      if (!identity) return reply.code(401).send({ error: "unauthorized" });
      const deleted = await deleteMemoryForControl({
        memoryId: request.params.id,
        scopes: visibleScopes(request.user.username),
        coupleId: identity.coupleId,
        accountId: identity.accountId,
        editorAccountId: identity.accountId,
        editorDeviceId: request.user.deviceId,
      });
      if (!deleted) return reply.code(404).send({ error: "memory_not_found" });
      return { ok: true };
    },
  );

  app.post("/api/me/memory/refresh", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const identity = await activeIdentity(request.user);
    if (!identity) return reply.code(401).send({ error: "unauthorized" });
    const parsed = refreshBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    const channel = parsed.data.scope === "shared" ? "couple" : `ai:${request.user.username}`;
    await flushMemory(channel);
    return { ok: true, stats: await memoryStatsForScopes(visibleScopes(request.user.username), identity) };
  });
}
