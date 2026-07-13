import type { FastifyInstance, FastifyRequest } from "fastify";
import { requireAuth } from "../../auth/httpAuth";
import { config } from "../../config";
import { AI_DEBUG_PAGE } from "./page";
import { getLiveTrace, listLiveTraces, type TraceEntry } from "./trace";
import { listPublicAccounts } from "../../auth/accounts";
import { flushMemory } from "../memory/extractor";
import { MEMORY_LAYERS, listMemoryForDebug, memoryStats, reconcileMemoryLifecycle, type MemoryLayer } from "../memory/store";
import { transaction, type MessageRow } from "../../db";

function isLoopback(request: FastifyRequest): boolean {
  if (config.isProduction) return false;
  const ip = request.ip.replace(/^::ffff:/, "");
  return ip === "127.0.0.1" || ip === "::1";
}

function canRead(trace: TraceEntry, username: string): boolean {
  return trace.channel === "couple" || trace.channel === `ai:${username}`;
}

export async function registerAiDebugRoutes(app: FastifyInstance) {
  app.get("/ai-debug", async (request, reply) => {
    if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
    return reply.type("text/html; charset=utf-8").send(AI_DEBUG_PAGE);
  });

  app.get<{ Params: { id: string } }>(
    "/api/ai-debug/traces/:id",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
      const trace = getLiveTrace(request.params.id);
      if (!trace) return reply.code(404).send({ error: "trace_not_found" });
      if (!request.user || !canRead(trace, request.user.username)) {
        return reply.code(403).send({ error: "forbidden" });
      }
      return { ok: true, trace };
    },
  );

  app.get<{ Querystring: { since?: string } }>(
    "/api/ai-debug/traces",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      const since = Number(request.query.since ?? 0);
      const traces = listLiveTraces(Number.isFinite(since) ? since : 0)
        .filter((trace) => canRead(trace, request.user!.username));
      return { ok: true, traces };
    },
  );

  app.get<{ Querystring: { channel?: "couple" | "ai"; username?: string; layer?: string; status?: string; limit?: string } }>(
    "/api/ai-debug/memory",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      const requestedUsername = request.query.username || request.user.username;
      if (request.query.channel === "ai" && requestedUsername !== request.user.username) {
        return reply.code(403).send({ error: "forbidden" });
      }
      const scopes = request.query.channel === "ai" ? ["couple", `ai:${requestedUsername}`] : ["couple"];
      const layer = MEMORY_LAYERS.includes(request.query.layer as MemoryLayer)
        ? request.query.layer as MemoryLayer
        : undefined;
      const status = String(request.query.status ?? "active").trim();
      const items = await listMemoryForDebug({
        scopes,
        layer,
        status: status === "all" ? undefined : status,
        limit: Number(request.query.limit) || 80,
      });
      return { ok: true, scopes, items };
    },
  );

  app.delete<{ Body: { channel?: "couple" | "ai"; username?: string; limit?: number } }>(
    "/api/ai-debug/messages/recent",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      const requestedUsername = request.body?.username || request.user.username;
      if (request.body?.channel === "ai" && requestedUsername !== request.user.username) {
        return reply.code(403).send({ error: "forbidden" });
      }
      const channel = request.body?.channel === "ai" ? `ai:${requestedUsername}` : "couple";
      const limit = Math.max(1, Math.min(200, Math.round(Number(request.body?.limit) || 100)));
      const deleted = await transaction(async (db) => {
        const rows = await db.all<Pick<MessageRow, "id">>(
          "SELECT id FROM messages WHERE channel = ? ORDER BY ts DESC LIMIT ? FOR UPDATE",
          [channel, limit],
        );
        if (!rows.length) return 0;
        await db.run(`DELETE FROM messages WHERE id IN (${rows.map(() => "?").join(",")})`, rows.map((row) => row.id));
        await db.run("DELETE FROM ai_runtime_state WHERE key = ?", [`context:${channel}`]);
        const latest = await db.get<{ ts: number; id: string }>(
          "SELECT ts, id FROM messages WHERE channel = ? ORDER BY ts DESC, id DESC LIMIT 1",
          [channel],
        );
        await db.run(
          "UPDATE ai_memory_cursor SET cursor_ts = ?, cursor_id = ?, updated_at = ? WHERE channel = ?",
          [latest?.ts ?? Date.now(), latest?.id ?? "", Date.now(), channel],
        );
        return rows.length;
      });
      await reconcileMemoryLifecycle();
      return { ok: true, channel, deleted };
    },
  );

  app.post<{ Body: { channel?: "couple" | "ai"; username?: string } }>(
    "/api/ai-debug/memory/flush",
    async (request, reply) => {
      if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
      const publicAccounts = await listPublicAccounts();
      const user = publicAccounts.find((account) => account.username === request.body?.username) ?? publicAccounts[0];
      if (!user) return reply.code(503).send({ error: "account_unavailable" });
      const channel = request.body?.channel === "ai" ? `ai:${user.username}` : "couple";
      await flushMemory(channel);
      return { ok: true, channel, stats: await memoryStats() };
    },
  );
}
