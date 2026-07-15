import { nanoid } from "nanoid";
import {
  all,
  get,
  run,
  transaction,
  type AiMemoryRow,
} from "../../db";
import { embedOne, embeddingEnabled, packVector, similarity, unpackVector } from "../embeddings";
import { searchTerms } from "../conversation/search";
import { appendSyncEvent } from "../../sync/events";

export const MEMORY_LAYERS = ["fact", "event", "plan", "state", "relationship", "insight"] as const;
export type MemoryLayer = typeof MEMORY_LAYERS[number];

export const MEMORY_PERSPECTIVES = ["people", "daju"] as const;
export type MemoryPerspective = typeof MEMORY_PERSPECTIVES[number];

export const MEMORY_KINDS = ["standard", "instruction", "observation"] as const;
export type MemoryKind = typeof MEMORY_KINDS[number];

export interface MemoryItem {
  id: string;
  layer: MemoryLayer;
  perspective: MemoryPerspective;
  kind: MemoryKind;
  scope: string;
  memoryKey: string;
  subjects: string[];
  speakers: string[];
  content: string;
  category: string;
  confidence: number;
  importance: number;
  occurredAt: number | null;
  occurredEndAt: number | null;
  validFrom: number | null;
  validUntil: number | null;
  status: string;
  supersedesId: string | null;
  metadata: Record<string, unknown>;
  vector: Float32Array | null;
  createdAt: number;
  updatedAt: number;
  version: number;
}

export interface MemoryCandidate {
  layer: MemoryLayer;
  perspective?: MemoryPerspective;
  kind?: MemoryKind;
  scope: string;
  memoryKey: string;
  subjects: string[];
  speakers: string[];
  content: string;
  category?: string;
  confidence?: number;
  importance?: number;
  occurredAt?: number | null;
  occurredEndAt?: number | null;
  validFrom?: number | null;
  validUntil?: number | null;
  metadata?: Record<string, unknown>;
  sourceMemoryIds?: string[];
  targetMemoryId?: string;
}

export interface MemoryWriteSync {
  actorAccountId: string;
  actorDeviceId?: string | null;
  restoreExcluded?: boolean;
}

export interface MemoryCursor {
  ts: number;
  id: string;
}

export type MemoryTransitionStatus = "retracted" | "completed" | "cancelled";

function parseArray(value: string): string[] {
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
}

function parseObject(value: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function mapItem(row: AiMemoryRow): MemoryItem {
  return {
    id: row.id,
    layer: row.layer as MemoryLayer,
    perspective: (row.perspective ?? "people") as MemoryPerspective,
    kind: (row.memory_kind ?? "standard") as MemoryKind,
    scope: row.scope,
    memoryKey: row.memory_key,
    subjects: parseArray(row.subjects_json),
    speakers: parseArray(row.speakers_json),
    content: row.content,
    category: row.category,
    confidence: row.confidence,
    importance: row.importance,
    occurredAt: row.occurred_at,
    occurredEndAt: row.occurred_end_at,
    validFrom: row.valid_from,
    validUntil: row.valid_until,
    status: row.status,
    supersedesId: row.supersedes_id,
    metadata: parseObject(row.metadata_json),
    vector: unpackVector(row.embedding),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    version: row.version ?? 0,
  };
}

function clamp(value: number | undefined, min: number, max: number, fallback: number): number {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(min, Math.min(max, number)) : fallback;
}

function normalizedKey(candidate: MemoryCandidate): string {
  const supplied = candidate.memoryKey.trim().toLowerCase().replace(/[^a-z0-9_.:\-\u4e00-\u9fff]+/g, "_");
  if (supplied) return supplied.slice(0, 160);
  return `${candidate.layer}:${candidate.subjects.sort().join("+")}:${candidate.category ?? "general"}:${candidate.content.slice(0, 50)}`;
}

function embeddingText(input: {
  layer: MemoryLayer;
  perspective?: MemoryPerspective;
  kind?: MemoryKind;
  category?: string | null;
  subjects: string[];
  content: string;
}): string {
  return `${input.perspective ?? "people"} ${input.kind ?? "standard"} ${input.layer} ${input.category ?? ""} ${input.subjects.join(" ")} ${input.content}`;
}

const LOGICAL_MEMORY_SUBJECTS = new Set(["xu", "si", "both"]);

export function normalizedMemorySubjects(values: string[]): string[] {
  const subjects = [...new Set(values.map((value) => value.trim().toLowerCase()))]
    .filter((value) => LOGICAL_MEMORY_SUBJECTS.has(value));
  if (subjects.includes("both") || (subjects.includes("xu") && subjects.includes("si"))) return ["both"];
  return subjects.length === 1 ? subjects : [];
}

export function visibleMemoryScopes(storedChannel: string): string[] {
  return storedChannel.startsWith("ai:") ? ["couple", storedChannel] : ["couple"];
}

export async function initializeMemoryCursor(channel: string, conversationId?: string): Promise<void> {
  const existing = await get<{ channel: string }>("SELECT channel FROM ai_memory_cursor WHERE channel = ?", [channel]);
  if (existing) return;
  const latest = await get<{ ts: number; id: string }>(
    conversationId
      ? "SELECT ts, id FROM messages WHERE conversation_id = ? ORDER BY ts DESC, id DESC LIMIT 1"
      : "SELECT ts, id FROM messages WHERE channel = ? ORDER BY ts DESC, id DESC LIMIT 1",
    [conversationId ?? channel],
  );
  const now = Date.now();
  await run(
    `INSERT INTO ai_memory_cursor (channel, cursor_ts, cursor_id, initialized_at, updated_at)
     VALUES (?, ?, ?, ?, ?) ON CONFLICT(channel) DO NOTHING`,
    [channel, latest?.ts ?? now, latest?.id ?? "", now, now],
  );
}

export async function memoryCursor(channel: string): Promise<MemoryCursor> {
  const row = await get<{ cursor_ts: number; cursor_id: string }>(
    "SELECT cursor_ts, cursor_id FROM ai_memory_cursor WHERE channel = ?",
    [channel],
  );
  return { ts: row?.cursor_ts ?? 0, id: row?.cursor_id ?? "" };
}

export async function advanceMemoryCursor(channel: string, cursor: MemoryCursor): Promise<void> {
  await run(
    `UPDATE ai_memory_cursor
     SET cursor_ts = ?, cursor_id = ?, updated_at = ?
     WHERE channel = ? AND (cursor_ts < ? OR (cursor_ts = ? AND cursor_id < ?))`,
    [cursor.ts, cursor.id, Date.now(), channel, cursor.ts, cursor.ts, cursor.id],
  );
}

export interface ResolvedMemoryOwner {
  coupleId: string | null;
  accountId: string | null;
}

async function resolveMemoryOwner(scope: string): Promise<ResolvedMemoryOwner | null> {
  if (scope === "couple") {
    const couple = await get<{ couple_id: string }>(
      "SELECT id AS couple_id FROM couples WHERE id = 'cpl_legacy_xusi'",
    );
    return couple ? { coupleId: couple.couple_id, accountId: null } : null;
  }
  if (scope.startsWith("ai:")) {
    const account = await get<{ id: string }>(
      "SELECT id FROM accounts WHERE username = ? AND status = 'active'",
      [scope.slice("ai:".length)],
    );
    return account ? { coupleId: null, accountId: account.id } : null;
  }
  return null;
}

function memoryOwnerSQL(owner: ResolvedMemoryOwner): { clause: string; value: string } {
  return owner.coupleId
    ? { clause: "couple_id = ?", value: owner.coupleId }
    : { clause: "owner_account_id = ?", value: owner.accountId! };
}

export async function addMemory(
  candidate: MemoryCandidate,
  sync?: MemoryWriteSync,
): Promise<MemoryItem | null> {
  const content = candidate.content.replace(/\s+/g, " ").trim().slice(0, 1200);
  const subjects = normalizedMemorySubjects(candidate.subjects);
  const requestedSourceMemoryIds = [...new Set(candidate.sourceMemoryIds ?? [])];
  if (content.length < 3 || subjects.length !== 1) return null;
  const perspective = candidate.perspective ?? "people";
  const kind = candidate.kind ?? "standard";
  if (!MEMORY_PERSPECTIVES.includes(perspective) || !MEMORY_KINDS.includes(kind)) return null;
  if (perspective === "people" && kind !== "standard") return null;
  if (perspective === "daju" && kind === "standard") return null;
  const memoryKey = normalizedKey(candidate);
  const now = Date.now();
  const confidence = clamp(candidate.confidence, 0, 1, 0.7);
  const importance = Math.round(clamp(candidate.importance, 1, 5, 3));
  const owner = await resolveMemoryOwner(candidate.scope);
  if (!owner) return null;
  const ownerSQL = memoryOwnerSQL(owner);
  const sourceMemories = requestedSourceMemoryIds.length
    ? await all<AiMemoryRow>(
        `SELECT * FROM ai_memory
         WHERE id IN (${requestedSourceMemoryIds.map(() => "?").join(",")})
           AND scope = ? AND layer IN ('fact','event','plan','state')
           AND status <> 'retracted' AND ${ownerSQL.clause}`,
        [...requestedSourceMemoryIds, candidate.scope, ownerSQL.value],
      )
    : [];
  if ((candidate.layer === "relationship" || candidate.layer === "insight") && sourceMemories.length === 0) return null;
  const excluded = await get<{ found: number }>(
    `SELECT 1 AS found FROM ai_memory_exclusions exclusion
     WHERE ${owner.coupleId ? "exclusion.couple_id = ?" : "exclusion.account_id = ?"}
       AND exclusion.memory_key = ?
       AND exclusion.source_message_id IS NULL
     LIMIT 1`,
    [ownerSQL.value, memoryKey],
  );
  if (excluded && !sync?.restoreExcluded) return null;

  let embedding: Uint8Array | null = null;
  if (embeddingEnabled()) {
    const vector = await embedOne(embeddingText({
      layer: candidate.layer,
      perspective,
      kind,
      category: candidate.category,
      subjects,
      content,
    }));
    if (vector) embedding = packVector(vector);
  }

  const versioned = candidate.layer !== "event";
  const rolling = candidate.layer === "state"
    || candidate.layer === "relationship"
    || candidate.layer === "insight";
  return transaction(async (db) => {
    if (excluded && sync?.restoreExcluded) {
      await db.run(
        `DELETE FROM ai_memory_exclusions
         WHERE ${owner.coupleId ? "couple_id = ?" : "account_id = ?"}
           AND memory_key = ? AND source_message_id IS NULL`,
        [ownerSQL.value, memoryKey],
      );
    }
    const finishWrite = async (row: AiMemoryRow): Promise<MemoryItem> => {
      if (!sync) return mapItem(row);
      const version = await appendSyncEvent(db, {
        coupleId: row.couple_id,
        accountId: row.owner_account_id,
        entityType: "memory",
        entityId: row.id,
        operation: "upsert",
        payload: controlItem(row, sourceMemories.length),
        actorAccountId: sync.actorAccountId,
        actorDeviceId: sync.actorDeviceId,
        createdAt: now,
      });
      await db.run("UPDATE ai_memory SET version = ? WHERE id = ?", [version, row.id]);
      return mapItem({ ...row, version });
    };
    const target = candidate.targetMemoryId && versioned
      ? await db.get<AiMemoryRow>(
           `SELECT * FROM ai_memory
           WHERE id = ? AND scope = ? AND layer = ? AND perspective = ? AND memory_kind = ? AND status = 'active'
             AND ${ownerSQL.clause}
           FOR UPDATE`,
          [candidate.targetMemoryId, candidate.scope, candidate.layer, perspective, kind, ownerSQL.value],
        )
      : undefined;
    if (candidate.targetMemoryId && versioned && !target) return null;
    const existing = target ?? (versioned
      ? rolling
        ? await db.get<AiMemoryRow>(
             `SELECT * FROM ai_memory
              WHERE scope = ? AND layer = ? AND perspective = ? AND memory_kind = ? AND status = 'active'
                AND ${ownerSQL.clause}
               ${candidate.layer === "state" ? "AND subjects_json::jsonb = CAST(? AS jsonb)" : ""}
             ORDER BY updated_at DESC, created_at DESC, id DESC LIMIT 1 FOR UPDATE`,
            [candidate.scope, candidate.layer, perspective, kind, ownerSQL.value,
              ...(candidate.layer === "state" ? [JSON.stringify(subjects)] : [])],
          )
        : await db.get<AiMemoryRow>(
             `SELECT * FROM ai_memory
              WHERE scope = ? AND layer = ? AND perspective = ? AND memory_kind = ? AND memory_key = ? AND status = 'active'
                AND ${ownerSQL.clause}
             ORDER BY updated_at DESC LIMIT 1 FOR UPDATE`,
            [candidate.scope, candidate.layer, perspective, kind, memoryKey, ownerSQL.value],
          )
      : await db.get<AiMemoryRow>(
           `SELECT m.* FROM ai_memory m
            WHERE m.scope = ? AND m.layer = 'event' AND m.perspective = ? AND m.memory_kind = ?
              AND m.memory_key = ? AND m.content = ?
             AND m.${owner.coupleId ? "couple_id" : "owner_account_id"} = ?
             AND m.status = 'active'
           LIMIT 1 FOR UPDATE`,
          [candidate.scope, perspective, kind, memoryKey, content, ownerSQL.value],
        ));
    const finalMemoryKey = target?.memory_key ?? (rolling ? memoryKey : existing?.memory_key ?? memoryKey);

    if (existing && existing.content === content) {
      const refreshedValidFrom = candidate.validFrom ?? existing.valid_from;
      const refreshedValidUntil = candidate.validUntil === undefined || candidate.validUntil === null
        ? existing.valid_until
        : existing.valid_until === null
          ? candidate.validUntil
          : Math.max(existing.valid_until, candidate.validUntil);
      await db.run(
        `UPDATE ai_memory SET confidence = GREATEST(confidence, ?),
         importance = GREATEST(importance, ?), valid_from = ?, valid_until = ?, updated_at = ?
         WHERE id = ?`,
        [confidence, importance, refreshedValidFrom, refreshedValidUntil, now, existing.id],
      );
      for (const source of sourceMemories) {
        await db.run(
          `INSERT INTO ai_memory_dependencies (memory_id, source_memory_id, role, created_at)
           VALUES (?, ?, 'source', ?) ON CONFLICT(memory_id, source_memory_id) DO NOTHING`,
          [existing.id, source.id, now],
        );
      }
      return finishWrite({
        ...existing,
        confidence: Math.max(existing.confidence, confidence),
        importance: Math.max(existing.importance, importance),
        valid_from: refreshedValidFrom,
        valid_until: refreshedValidUntil,
        updated_at: now,
      });
    }

    const id = `mem_${nanoid(16)}`;
    if (existing && versioned) {
      await db.run("UPDATE ai_memory SET status = 'superseded', updated_at = ? WHERE id = ?", [now, existing.id]);
    }
    await db.run(
      `INSERT INTO ai_memory
       (id, layer, perspective, memory_kind, scope, memory_key, subjects_json, speakers_json, content, category,
        confidence, importance, occurred_at, occurred_end_at, valid_from, valid_until,
        status, supersedes_id, metadata_json, embedding, created_at, updated_at,
        couple_id, owner_account_id, version)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?, 0)`,
      [
        id,
        candidate.layer,
        perspective,
        kind,
        candidate.scope,
        finalMemoryKey,
        JSON.stringify(subjects),
        JSON.stringify([...new Set(candidate.speakers)]),
        content,
        String(candidate.category ?? "").slice(0, 80),
        confidence,
        importance,
        candidate.occurredAt ?? null,
        candidate.occurredEndAt ?? null,
        candidate.validFrom ?? null,
        candidate.validUntil ?? null,
        versioned ? existing?.id ?? null : null,
        JSON.stringify(candidate.metadata ?? {}),
        embedding,
        now,
        now,
        owner.coupleId,
        owner.accountId,
      ],
    );
    for (const source of sourceMemories) {
      await db.run(
        `INSERT INTO ai_memory_dependencies (memory_id, source_memory_id, role, created_at)
         VALUES (?, ?, 'source', ?) ON CONFLICT(memory_id, source_memory_id) DO NOTHING`,
        [id, source.id, now],
      );
    }
    const row = await db.get<AiMemoryRow>("SELECT * FROM ai_memory WHERE id = ?", [id]);
    return row ? finishWrite(row) : null;
  });
}

export async function listActiveMemoryContext(
  scope: string,
  limit = 80,
  owner: ResolvedMemoryOwner | null = null,
): Promise<MemoryItem[]> {
  const ownerSQL = owner ? memoryOwnerSQL(owner) : null;
  const rows = await all<AiMemoryRow>(
    `SELECT * FROM ai_memory
     WHERE scope = ? AND status = 'active'
       ${ownerSQL ? `AND ${ownerSQL.clause}` : ""}
     ORDER BY CASE WHEN layer = 'event' THEN 1 ELSE 0 END, updated_at DESC LIMIT ?`,
    ownerSQL
      ? [scope, ownerSQL.value, Math.max(1, Math.min(200, limit))]
      : [scope, Math.max(1, Math.min(200, limit))],
  );
  return rows.map(mapItem);
}

export async function repairMissingMemoryEmbeddings(limit = 25): Promise<number> {
  if (!embeddingEnabled()) return 0;
  const rows = await all<AiMemoryRow>(
    `SELECT * FROM ai_memory
     WHERE status = 'active' AND embedding IS NULL
     ORDER BY updated_at DESC LIMIT ?`,
    [Math.max(1, Math.min(100, limit))],
  );
  let repaired = 0;
  for (const row of rows) {
    const item = mapItem(row);
    const vector = await embedOne(embeddingText(item));
    if (!vector) continue;
    repaired += await run(
      "UPDATE ai_memory SET embedding = ? WHERE id = ? AND embedding IS NULL",
      [packVector(vector), item.id],
    );
  }
  return repaired;
}

export async function transitionMemory(input: {
  memoryId: string;
  scope: string;
  status: MemoryTransitionStatus;
  reason?: string;
}): Promise<boolean> {
  const now = Date.now();
  return transaction(async (db) => {
    const target = await db.get<AiMemoryRow>(
      "SELECT * FROM ai_memory WHERE id = ? AND scope = ? AND status = 'active' FOR UPDATE",
      [input.memoryId, input.scope],
    );
    if (!target) return false;
    const metadata = { ...parseObject(target.metadata_json), transitionReason: input.reason ?? "", transitionedAt: now };
    await db.run(
      "UPDATE ai_memory SET status = ?, metadata_json = ?, updated_at = ? WHERE id = ?",
      [input.status, JSON.stringify(metadata), now, target.id],
    );
    return true;
  });
}

export async function expireMemoryStates(now = Date.now()): Promise<number> {
  return run(
    `UPDATE ai_memory SET status = 'expired', updated_at = ?
     WHERE (layer IN ('state', 'plan')
       OR (perspective = 'daju' AND memory_kind = 'observation'))
       AND status = 'active'
       AND valid_until IS NOT NULL AND valid_until <= ?`,
    [now, now],
  );
}

export async function reconcileMemoryLifecycle(now = Date.now()): Promise<{ expired: number; retracted: number }> {
  const expired = await expireMemoryStates(now);
  const retracted = await run(
    `UPDATE ai_memory memory SET status = 'retracted', updated_at = ?
     WHERE memory.status = 'active' AND memory.layer IN ('relationship', 'insight')
       AND NOT EXISTS (
         SELECT 1 FROM ai_memory_dependencies dependency
         JOIN ai_memory source ON source.id = dependency.source_memory_id
         WHERE dependency.memory_id = memory.id AND source.status <> 'retracted'
       )`,
    [now],
  );
  return { expired, retracted };
}

export type MemorySearchSort = "relevance" | "importance" | "recent";

export interface SearchMemoryInput {
  query: string;
  layers: MemoryLayer[];
  scopes: string[];
  perspectives?: MemoryPerspective[];
  kinds?: MemoryKind[];
  subjects?: string[];
  subjectMode?: "related" | "exact";
  from?: number;
  to?: number;
  limit?: number;
  sort?: MemorySearchSort;
}

export async function searchMemory(input: SearchMemoryInput): Promise<Array<MemoryItem & { score: number; lexicalHits: number }>> {
  if (!input.layers.length || !input.scopes.length) return [];
  await expireMemoryStates();
  const clauses = [
    `layer IN (${input.layers.map(() => "?").join(",")})`,
    `scope IN (${input.scopes.map(() => "?").join(",")})`,
    `perspective IN (${(input.perspectives?.length ? input.perspectives : ["people"]).map(() => "?").join(",")})`,
    "status = 'active'",
  ];
  const params: Array<string | number> = [
    ...input.layers,
    ...input.scopes,
    ...(input.perspectives?.length ? input.perspectives : ["people"]),
  ];
  if (input.kinds?.length) {
    clauses.push(`memory_kind IN (${input.kinds.map(() => "?").join(",")})`);
    params.push(...input.kinds);
  }
  const eventOnly = input.layers.length === 1 && input.layers[0] === "event";
  const timeColumn = eventOnly ? "occurred_at" : "COALESCE(occurred_at, valid_from, created_at)";
  if (input.from) { clauses.push(`${timeColumn} >= ?`); params.push(input.from); }
  if (input.to) { clauses.push(`${timeColumn} <= ?`); params.push(input.to); }
  const rows = await all<AiMemoryRow>(
    `SELECT * FROM ai_memory WHERE ${clauses.join(" AND ")} ORDER BY updated_at DESC LIMIT 10000`,
    params,
  );
  const subjects = new Set(input.subjects ?? []);
  const filtered = rows.map(mapItem).filter((item) => subjects.size === 0
    || item.subjects.some((subject) => subjects.has(subject))
    || (input.subjectMode !== "exact" && item.subjects.includes("both")));
  const vector = input.query.trim() && embeddingEnabled() ? await embedOne(input.query) : null;
  const terms = searchTerms(input.query);
  const scored = filtered.map((item) => {
    const lower = item.content.toLowerCase();
    const hits = terms.reduce((count, term) => count + (lower.includes(term) ? 1 : 0), 0);
    const score = vector && item.vector ? similarity(vector, item.vector) : 0;
    return { ...item, score, lexicalHits: hits };
  });
  const sort = input.sort ?? (input.query.trim() ? "relevance" : "importance");
  return scored
    .filter((item) => !input.query.trim() || item.lexicalHits > 0 || item.score >= 0.38)
    .sort((a, b) => sort === "recent"
      ? b.updatedAt - a.updatedAt || b.importance - a.importance
      : sort === "importance"
        ? b.importance - a.importance || b.updatedAt - a.updatedAt
        : b.lexicalHits - a.lexicalHits || b.score - a.score
          || b.importance - a.importance || b.updatedAt - a.updatedAt)
    .slice(0, Math.max(1, Math.min(20, input.limit ?? 8)));
}

export async function memorySources(
  memoryId: string,
  scopes: string[],
  access: Omit<MemoryControlAccess, "scopes"> = {},
): Promise<Array<Omit<MemoryItem, "vector">>> {
  if (!scopes.length) return [];
  const ownership: string[] = [];
  const ownerParams: string[] = [];
  if (access.coupleId) { ownership.push("parent.couple_id = ?"); ownerParams.push(access.coupleId); }
  if (access.accountId) { ownership.push("parent.owner_account_id = ?"); ownerParams.push(access.accountId); }
  const rows = await all<AiMemoryRow>(
    `SELECT source.* FROM ai_memory_dependencies dependency
     JOIN ai_memory parent ON parent.id = dependency.memory_id
     JOIN ai_memory source ON source.id = dependency.source_memory_id
     WHERE parent.id = ? AND parent.scope IN (${scopes.map(() => "?").join(",")})
       ${ownership.length ? `AND (${ownership.join(" OR ")})` : ""}
     ORDER BY COALESCE(source.occurred_at, source.valid_from, source.updated_at) DESC
     LIMIT 60`,
    [memoryId, ...scopes, ...ownerParams],
  );
  return rows.map((row) => {
    const { vector: _vector, ...item } = mapItem(row);
    return item;
  });
}

export async function memoryStats(): Promise<Record<string, number>> {
  const rows = await all<{ layer: string; count: number }>(
    "SELECT layer, COUNT(*) AS count FROM ai_memory WHERE status = 'active' GROUP BY layer",
  );
  return Object.fromEntries(rows.map((row) => [row.layer, row.count]));
}

export type MemoryControlItem = Omit<MemoryItem, "vector"> & {
  evidenceCount: number;
  derivedFromCount: number;
};

export interface MemoryControlAccess {
  scopes: string[];
  coupleId?: string | null;
  accountId?: string | null;
}

export interface MemoryControlFilter {
  scopes: string[];
  coupleId?: string | null;
  accountId?: string | null;
  layer?: MemoryLayer;
  perspective?: MemoryPerspective;
  kind?: MemoryKind;
  status?: string;
  subject?: "xu" | "si" | "both";
  query?: string;
  limit?: number;
  cursor?: { updatedAt: number; id: string };
}

function addControlOwnership(
  access: MemoryControlAccess,
  clauses: string[],
  params: Array<string | number>,
): void {
  if (!access.coupleId && !access.accountId) return;
  const shared = access.scopes.includes("couple") && access.coupleId;
  const privateScope = access.scopes.some((scope) => scope.startsWith("ai:")) && access.accountId;
  if (shared && privateScope) {
    clauses.push("(couple_id = ? OR owner_account_id = ?)");
    params.push(shared, privateScope);
  } else if (shared) {
    clauses.push("couple_id = ?");
    params.push(shared);
  } else if (privateScope) {
    clauses.push("owner_account_id = ?");
    params.push(privateScope);
  } else {
    clauses.push("FALSE");
  }
}

function controlItem(row: AiMemoryRow, derivedFromCount = 0): MemoryControlItem {
  const { vector: _vector, ...item } = mapItem(row);
  // evidenceCount 暂留为兼容旧客户端的恒定字段；新系统不再保存原始消息证据。
  return { ...item, evidenceCount: 0, derivedFromCount };
}

export async function listMemoryForControl(input: MemoryControlFilter): Promise<MemoryControlItem[]> {
  if (!input.scopes.length) return [];
  const clauses = [`scope IN (${input.scopes.map(() => "?").join(",")})`];
  const params: Array<string | number> = [...input.scopes];
  addControlOwnership(input, clauses, params);
  if (input.layer) {
    clauses.push("layer = ?");
    params.push(input.layer);
  }
  if (input.status) {
    clauses.push("status = ?");
    params.push(input.status);
  }
  if (input.perspective) {
    clauses.push("perspective = ?");
    params.push(input.perspective);
  }
  if (input.kind) {
    clauses.push("memory_kind = ?");
    params.push(input.kind);
  }
  if (input.subject) {
    clauses.push("subjects_json::jsonb = CAST(? AS jsonb)");
    params.push(JSON.stringify([input.subject]));
  }
  const query = input.query?.replace(/\s+/g, " ").trim().slice(0, 120);
  if (query) {
    clauses.push("(content ILIKE ? OR category ILIKE ? OR subjects_json ILIKE ?)");
    params.push(`%${query}%`, `%${query}%`, `%${query}%`);
  }
  if (input.cursor) {
    clauses.push("(updated_at < ? OR (updated_at = ? AND id < ?))");
    params.push(input.cursor.updatedAt, input.cursor.updatedAt, input.cursor.id);
  }
  params.push(Math.max(1, Math.min(201, input.limit ?? 100)));
  const rows = await all<AiMemoryRow>(
    `SELECT * FROM ai_memory
     WHERE ${clauses.join(" AND ")}
     ORDER BY updated_at DESC, id DESC LIMIT ?`,
    params,
  );
  if (!rows.length) return [];
  const dependencyCounts = await all<{ memory_id: string; count: number }>(
    `SELECT memory_id, COUNT(*) AS count FROM ai_memory_dependencies
     WHERE memory_id IN (${rows.map(() => "?").join(",")}) GROUP BY memory_id`,
    rows.map((row) => row.id),
  );
  const dependencyCountById = new Map(dependencyCounts.map((row) => [row.memory_id, row.count]));
  return rows.map((row) => controlItem(
    row,
    dependencyCountById.get(row.id) ?? 0,
  ));
}

export async function getMemoryForControl(
  memoryId: string,
  access: MemoryControlAccess,
): Promise<MemoryControlItem | null> {
  if (!access.scopes.length) return null;
  const clauses = ["id = ?", `scope IN (${access.scopes.map(() => "?").join(",")})`];
  const params: Array<string | number> = [memoryId, ...access.scopes];
  addControlOwnership(access, clauses, params);
  const row = await get<AiMemoryRow>(
    `SELECT * FROM ai_memory WHERE ${clauses.join(" AND ")}`,
    params,
  );
  if (!row) return null;
  const dependencies = await get<{ count: number }>(
    "SELECT COUNT(*) AS count FROM ai_memory_dependencies WHERE memory_id = ?",
    [row.id],
  );
  return controlItem(row, dependencies?.count ?? 0);
}

export async function memoryStatsForScopes(
  scopes: string[],
  access: Omit<MemoryControlAccess, "scopes"> = {},
): Promise<{
  total: number;
  shared: number;
  private: number;
  byLayer: Record<string, number>;
  bySubject: Record<string, number>;
}> {
  if (!scopes.length) return { total: 0, shared: 0, private: 0, byLayer: {}, bySubject: {} };
  const clauses = ["status = 'active'", `scope IN (${scopes.map(() => "?").join(",")})`];
  const params: Array<string | number> = [...scopes];
  addControlOwnership({ scopes, ...access }, clauses, params);
  const rows = await all<{ scope: string; layer: string; subjects_json: string; count: number }>(
    `SELECT scope, layer, subjects_json, COUNT(*) AS count FROM ai_memory
     WHERE ${clauses.join(" AND ")}
     GROUP BY scope, layer, subjects_json`,
    params,
  );
  const byLayer: Record<string, number> = {};
  const bySubject: Record<string, number> = {};
  for (const row of rows) byLayer[row.layer] = (byLayer[row.layer] ?? 0) + row.count;
  for (const row of rows) {
    const subject = normalizedMemorySubjects(parseArray(row.subjects_json))[0] ?? "unknown";
    bySubject[subject] = (bySubject[subject] ?? 0) + row.count;
  }
  return {
    total: rows.reduce((sum, row) => sum + row.count, 0),
    shared: rows.filter((row) => row.scope === "couple").reduce((sum, row) => sum + row.count, 0),
    private: rows.filter((row) => row.scope !== "couple").reduce((sum, row) => sum + row.count, 0),
    byLayer,
    bySubject,
  };
}

export async function archiveSiblingMemories(
  keepMemoryId: string,
  sameSubject: boolean,
  now = Date.now(),
): Promise<number> {
  const keep = await get<AiMemoryRow>("SELECT * FROM ai_memory WHERE id = ?", [keepMemoryId]);
  if (!keep) return 0;
  const ownerColumn = keep.couple_id ? "couple_id" : "owner_account_id";
  const ownerValue = keep.couple_id ?? keep.owner_account_id;
  if (!ownerValue) return 0;
  return run(
      `UPDATE ai_memory SET status = 'superseded', updated_at = ?
      WHERE id <> ? AND layer = ? AND perspective = ? AND memory_kind = ? AND scope = ? AND status = 'active'
        AND ${ownerColumn} = ?
       ${sameSubject ? "AND subjects_json::jsonb = CAST(? AS jsonb)" : ""}`,
    [now, keep.id, keep.layer, keep.perspective ?? "people", keep.memory_kind ?? "standard", keep.scope, ownerValue,
      ...(sameSubject ? [JSON.stringify(normalizedMemorySubjects(parseArray(keep.subjects_json)))] : [])],
  );
}

export async function updateMemoryForControl(input: {
  memoryId: string;
  scopes: string[];
  coupleId?: string | null;
  accountId?: string | null;
  content: string;
  importance?: number;
  editor: string;
  editorAccountId?: string | null;
  editorDeviceId?: string | null;
  baseVersion?: number;
}): Promise<MemoryControlItem | null> {
  const content = input.content.replace(/\s+/g, " ").trim().slice(0, 1200);
  if (content.length < 3 || !input.scopes.length) return null;
  const lookupClauses = ["id = ?", `scope IN (${input.scopes.map(() => "?").join(",")})`];
  const lookupParams: Array<string | number> = [input.memoryId, ...input.scopes];
  addControlOwnership(input, lookupClauses, lookupParams);
  const embeddingTarget = await get<AiMemoryRow>(
    `SELECT * FROM ai_memory WHERE ${lookupClauses.join(" AND ")}`,
    lookupParams,
  );
  if (!embeddingTarget) return null;
  let embedding: Uint8Array | null = null;
  if (embeddingEnabled()) {
    const item = mapItem(embeddingTarget);
    const vector = await embedOne(embeddingText({ ...item, content }));
    if (vector) embedding = packVector(vector);
  }
  return transaction(async (db) => {
    const clauses = ["id = ?", `scope IN (${input.scopes.map(() => "?").join(",")})`];
    const params: Array<string | number> = [input.memoryId, ...input.scopes];
    addControlOwnership(input, clauses, params);
    const target = await db.get<AiMemoryRow>(
      `SELECT * FROM ai_memory WHERE ${clauses.join(" AND ")} FOR UPDATE`,
      params,
    );
    if (!target) return null;
    if (input.baseVersion !== undefined && (target.version ?? 0) !== input.baseVersion) {
      throw new Error("memory_version_conflict");
    }
    const importance = input.importance === undefined
      ? target.importance
      : Math.round(clamp(input.importance, 1, 5, target.importance));
    const now = Date.now();
    const metadata = {
      ...parseObject(target.metadata_json),
      manuallyEditedAt: now,
      manuallyEditedBy: input.editor,
    };
    await db.run(
      `UPDATE ai_memory SET content = ?, importance = ?, metadata_json = ?,
       embedding = ?, updated_at = ? WHERE id = ?`,
      [content, importance, JSON.stringify(metadata), embedding, now, target.id],
    );
    let updated = await db.get<AiMemoryRow>("SELECT * FROM ai_memory WHERE id = ?", [target.id]);
    if (!updated) return null;
    const dependencies = await db.get<{ count: number }>(
      "SELECT COUNT(*) AS count FROM ai_memory_dependencies WHERE memory_id = ?",
      [target.id],
    );
    if (input.editorAccountId) {
      const version = await appendSyncEvent(db, {
        coupleId: target.couple_id,
        accountId: target.owner_account_id,
        entityType: "memory",
        entityId: target.id,
        operation: "upsert",
        payload: controlItem(updated, dependencies?.count ?? 0),
        actorAccountId: input.editorAccountId,
        actorDeviceId: input.editorDeviceId,
        createdAt: now,
      });
      await db.run("UPDATE ai_memory SET version = ? WHERE id = ?", [version, target.id]);
      updated = await db.get<AiMemoryRow>("SELECT * FROM ai_memory WHERE id = ?", [target.id]);
      if (!updated) return null;
    }
    return controlItem(updated, dependencies?.count ?? 0);
  });
}

export async function deleteMemoryForControl(input: {
  memoryId: string;
  scopes: string[];
  coupleId?: string | null;
  accountId?: string | null;
  editorAccountId: string;
  editorDeviceId?: string | null;
}): Promise<boolean> {
  if (!input.scopes.length) return false;
  return transaction(async (db) => {
    const clauses = ["id = ?", `scope IN (${input.scopes.map(() => "?").join(",")})`];
    const params: Array<string | number> = [input.memoryId, ...input.scopes];
    addControlOwnership(input, clauses, params);
    const target = await db.get<AiMemoryRow>(
      `SELECT * FROM ai_memory WHERE ${clauses.join(" AND ")} FOR UPDATE`,
      params,
    );
    if (!target) return false;
    await db.run(
      `INSERT INTO ai_memory_exclusions
       (id, couple_id, account_id, memory_key, source_message_id, created_by_account_id, created_at)
       VALUES (?, ?, ?, ?, NULL, ?, ?)
       ON CONFLICT DO NOTHING`,
      [`mex_${nanoid(16)}`, target.couple_id ?? null, target.owner_account_id ?? null,
        target.memory_key, input.editorAccountId, Date.now()],
    );
    await appendSyncEvent(db, {
      coupleId: target.couple_id,
      accountId: target.owner_account_id,
      entityType: "memory",
      entityId: target.id,
      operation: "delete",
      payload: { id: target.id },
      actorAccountId: input.editorAccountId,
      actorDeviceId: input.editorDeviceId,
    });
    await db.run("DELETE FROM ai_memory WHERE id = ?", [target.id]);
    return true;
  });
}

export interface MemoryDebugFilter {
  scopes: string[];
  layer?: MemoryLayer;
  status?: string;
  limit?: number;
}

export async function listMemoryForDebug(input: MemoryDebugFilter): Promise<MemoryItem[]> {
  if (!input.scopes.length) return [];
  const clauses = [`scope IN (${input.scopes.map(() => "?").join(",")})`];
  const params: Array<string | number> = [...input.scopes];
  if (input.layer) { clauses.push("layer = ?"); params.push(input.layer); }
  if (input.status) { clauses.push("status = ?"); params.push(input.status); }
  params.push(Math.max(1, Math.min(200, input.limit ?? 80)));
  const rows = await all<AiMemoryRow>(
    `SELECT * FROM ai_memory WHERE ${clauses.join(" AND ")} ORDER BY updated_at DESC LIMIT ?`,
    params,
  );
  return rows.map(mapItem);
}
