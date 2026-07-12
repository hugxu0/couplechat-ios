import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { all, run } from "../db";
import { requireAuth } from "../auth/httpAuth";
import { activeIdentity } from "../auth/identity";

const syncQuery = z.object({
  cursor: z.coerce.number().int().min(0).default(0),
  limit: z.coerce.number().int().min(1).max(500).default(200),
});

const ackBody = z.object({ cursor: z.number().int().min(0) });

interface SyncEventRow {
  seq: number;
  entity_type: string;
  entity_id: string;
  operation: "upsert" | "delete";
  entity_version: number;
  payload_json: string;
  created_at: number;
}

export async function registerSyncV2Routes(app: FastifyInstance) {
  app.get("/api/v2/sync", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const parsed = syncQuery.safeParse(request.query);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    const identity = await activeIdentity(request.user);
    if (!identity) return reply.code(401).send({ error: "unauthorized" });
    const rows = await all<SyncEventRow>(
      `SELECT seq, entity_type, entity_id, operation, entity_version, payload_json, created_at
         FROM sync_events
        WHERE seq > ? AND (account_id = ? OR couple_id = ?)
        ORDER BY seq ASC LIMIT ?`,
      [parsed.data.cursor, identity.accountId, identity.coupleId ?? "", parsed.data.limit + 1],
    );
    const page = rows.slice(0, parsed.data.limit);
    return {
      protocolVersion: 2,
      events: page.map((row) => ({
        seq: row.seq,
        entityType: row.entity_type,
        entityId: row.entity_id,
        operation: row.operation,
        version: row.entity_version,
        payload: JSON.parse(row.payload_json) as unknown,
        createdAt: row.created_at,
      })),
      nextCursor: page.at(-1)?.seq ?? parsed.data.cursor,
      hasMore: rows.length > parsed.data.limit,
    };
  });

  app.post("/api/v2/sync/ack", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user?.deviceId) return reply.code(403).send({ error: "device_session_required" });
    const parsed = ackBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    await run(
      `INSERT INTO device_sync_cursors (device_id, last_ack_seq, updated_at)
       VALUES (?, ?, ?)
       ON CONFLICT(device_id) DO UPDATE SET
         last_ack_seq = GREATEST(device_sync_cursors.last_ack_seq, excluded.last_ack_seq),
         updated_at = excluded.updated_at`,
      [request.user.deviceId, parsed.data.cursor, Date.now()],
    );
    return { ok: true };
  });
}
