import type { DatabaseTransaction } from "../db";

export interface SyncEventInput {
  coupleId?: string | null;
  accountId?: string | null;
  entityType: string;
  entityId: string;
  operation: "upsert" | "delete";
  payload: unknown;
  actorAccountId?: string | null;
  actorDeviceId?: string | null;
  mutationId?: string | null;
  createdAt?: number;
}

export async function appendSyncEvent(
  db: DatabaseTransaction,
  input: SyncEventInput,
): Promise<number> {
  if (Boolean(input.coupleId) === Boolean(input.accountId)) {
    throw new Error("sync_event_requires_exactly_one_scope");
  }
  const allocated = await db.get<{ seq: number }>("SELECT nextval('sync_event_seq') AS seq");
  if (!allocated) throw new Error("sync_sequence_unavailable");
  await db.run(
    `INSERT INTO sync_events
     (seq, couple_id, account_id, entity_type, entity_id, operation, entity_version,
      payload_json, actor_account_id, actor_device_id, mutation_id, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [allocated.seq, input.coupleId ?? null, input.accountId ?? null,
      input.entityType, input.entityId, input.operation, allocated.seq,
      JSON.stringify(input.payload), input.actorAccountId ?? null,
      input.actorDeviceId ?? null, input.mutationId ?? null, input.createdAt ?? Date.now()],
  );
  return allocated.seq;
}
