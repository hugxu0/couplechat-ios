import type { FastifyInstance, FastifyRequest } from "fastify";
import { requireAuth } from "../../auth/httpAuth";
import { config } from "../../config";
import { AI_DEBUG_PAGE } from "./page";
import { getLiveTrace, listLiveTraces, traceBegin, traceFlush, type TraceEntry } from "./trace";
import { runAgentReply } from "../agent/runtime";
import type { Trigger } from "../agent/replyQueue";
import { listPublicAccounts } from "../../auth/accounts";
import { flushMemory } from "../memory/extractor";
import { MEMORY_LAYERS, listMemoryForDebug, memoryStats, reconcileMemoryLifecycle, type MemoryLayer } from "../memory/store";
import { all, run, transaction, type MessageRow } from "../../db";

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

  // 不写消息、不广播的 Agent/MCP 烟雾测试；仅本机开发环境且仍要求真实登录。
  app.post<{ Body: { question?: string; channel?: "couple" | "ai"; username?: string } }>(
    "/api/ai-debug/agent-smoke",
    async (request, reply) => {
      if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
      const question = String(request.body?.question ?? "").trim();
      if (!question) return reply.code(400).send({ error: "question_required" });
      const publicAccounts = await listPublicAccounts();
      const user = publicAccounts.find((account) => account.username === request.body?.username) ?? publicAccounts[0];
      if (!user) return reply.code(503).send({ error: "account_unavailable" });
      const storedChannel = request.body?.channel === "couple" ? "couple" : `ai:${user.username}`;
      const trigger: Trigger = {
        storedChannel,
        question,
        requesterName: user.name,
        requesterUsername: user.username,
      };
      const trace = traceBegin(storedChannel, user.name, question);
      try {
        const result = await runAgentReply(trigger, trace);
        return { ok: Boolean(result), result, traceId: trace.id };
      } finally {
        traceFlush(trace);
      }
    },
  );

  app.get("/api/ai-debug/memory/stats", async (request, reply) => {
    if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
    return { ok: true, stats: await memoryStats() };
  });

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

  app.get<{ Querystring: { status?: string; limit?: string } }>(
    "/api/ai-debug/memory/import",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      const status = String(request.query.status ?? "all");
      const limit = Math.max(1, Math.min(100, Number(request.query.limit) || 40));
      const runs = await all<Record<string, unknown>>(
        "SELECT * FROM ai_memory_import_runs ORDER BY created_at DESC LIMIT 12",
      );
      const counts = await all<{ status: string; count: number }>(
        "SELECT status, COUNT(*)::int AS count FROM ai_memory_import_candidates GROUP BY status ORDER BY status",
      );
      const params: Array<string | number> = [];
      const where = status === "all" ? "" : "WHERE c.status = ?";
      if (status !== "all") params.push(status);
      params.push(limit);
      const candidates = await all<Record<string, unknown>>(
        `SELECT c.*,
          COALESCE(json_agg(json_build_object(
            'messageId', m.id, 'sender', m.sender, 'senderName', m.sender_name,
            'text', LEFT(m.text, 500), 'ts', m.ts, 'role', e.evidence_role
          ) ORDER BY m.ts) FILTER (WHERE m.id IS NOT NULL), '[]') AS evidence
         FROM ai_memory_import_candidates c
         LEFT JOIN ai_memory_import_evidence e ON e.candidate_id = c.id
         LEFT JOIN messages m ON m.id = e.message_id
         ${where}
         GROUP BY c.id ORDER BY c.created_at DESC LIMIT ?`,
        params,
      );
      return { ok: true, runs, counts: Object.fromEntries(counts.map((item) => [item.status, item.count])), candidates };
    },
  );

  app.post<{ Params: { id: string }; Body: { decision?: "approve" | "reject" } }>(
    "/api/ai-debug/memory/import/:id/decision",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!isLoopback(request)) return reply.code(404).send({ error: "not_found" });
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      const status = request.body?.decision === "approve" ? "approved"
        : request.body?.decision === "reject" ? "rejected"
          : null;
      if (!status) return reply.code(400).send({ error: "invalid_decision" });
      const changed = await run(
        `UPDATE ai_memory_import_candidates SET status = ?, updated_at = ?
         WHERE id = ? AND status IN ('needs_review','verified','approved')`,
        [status, Date.now(), request.params.id],
      );
      return { ok: changed > 0, status };
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
