import { nanoid } from "nanoid";
import {
  all,
  get,
  run,
  transaction,
  type AiMemoryEvidenceRow,
  type AiMemoryRow,
  type MessageRow,
} from "../../db";
import { embedOne, embeddingEnabled, packVector, similarity, unpackVector } from "../embeddings";
import { searchTerms } from "../conversation/search";

export const MEMORY_LAYERS = ["fact", "event", "plan", "state", "relationship", "insight"] as const;
export type MemoryLayer = typeof MEMORY_LAYERS[number];

export interface MemoryItem {
  id: string;
  layer: MemoryLayer;
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
}

export interface MemoryCandidate {
  layer: MemoryLayer;
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
  sourceMessageIds: string[];
  targetMemoryId?: string;
  allowWithoutEvidence?: boolean;
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

export function visibleMemoryScopes(storedChannel: string): string[] {
  return storedChannel.startsWith("ai:") ? ["couple", storedChannel] : ["couple"];
}

export async function initializeMemoryCursor(channel: string): Promise<void> {
  const existing = await get<{ channel: string }>("SELECT channel FROM ai_memory_cursor WHERE channel = ?", [channel]);
  if (existing) return;
  const latest = await get<{ ts: number; id: string }>(
    "SELECT ts, id FROM messages WHERE channel = ? ORDER BY ts DESC, id DESC LIMIT 1",
    [channel],
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

export async function addMemory(candidate: MemoryCandidate): Promise<MemoryItem | null> {
  const content = candidate.content.replace(/\s+/g, " ").trim().slice(0, 1200);
  if (content.length < 3 || (!candidate.allowWithoutEvidence && candidate.sourceMessageIds.length === 0)) return null;
  const memoryKey = normalizedKey(candidate);
  const now = Date.now();
  const confidence = clamp(candidate.confidence, 0, 1, 0.7);
  const importance = Math.round(clamp(candidate.importance, 1, 5, 3));
  const sourceRows = candidate.sourceMessageIds.length
    ? await all<MessageRow>(
        `SELECT * FROM messages
         WHERE id IN (${candidate.sourceMessageIds.map(() => "?").join(",")})
           AND kind = 'user' AND sender <> 'ai'
         ORDER BY ts ASC`,
        candidate.sourceMessageIds,
      )
    : [];
  if (!candidate.allowWithoutEvidence && sourceRows.length === 0) return null;

  let embedding: Uint8Array | null = null;
  if (embeddingEnabled()) {
    const vector = await embedOne(`${candidate.layer} ${candidate.category ?? ""} ${candidate.subjects.join(" ")} ${content}`);
    if (vector) embedding = packVector(vector);
  }

  const versioned = candidate.layer !== "event";
  return transaction(async (db) => {
    const target = candidate.targetMemoryId && versioned
      ? await db.get<AiMemoryRow>(
          `SELECT * FROM ai_memory
           WHERE id = ? AND scope = ? AND layer = ? AND status = 'active'
           FOR UPDATE`,
          [candidate.targetMemoryId, candidate.scope, candidate.layer],
        )
      : undefined;
    if (candidate.targetMemoryId && versioned && !target) return null;
    const finalMemoryKey = target?.memory_key ?? memoryKey;
    const existing = target ?? (versioned
      ? await db.get<AiMemoryRow>(
          `SELECT * FROM ai_memory
           WHERE scope = ? AND layer = ? AND memory_key = ? AND status = 'active'
           ORDER BY updated_at DESC LIMIT 1 FOR UPDATE`,
          [candidate.scope, candidate.layer, finalMemoryKey],
        )
      : sourceRows.length ? await db.get<AiMemoryRow>(
          `SELECT m.* FROM ai_memory m
           WHERE m.scope = ? AND m.layer = 'event' AND m.memory_key = ? AND m.content = ?
             AND EXISTS (
               SELECT 1 FROM ai_memory_evidence e
               WHERE e.memory_id = m.id
                 AND e.message_id IN (${sourceRows.map(() => "?").join(",")})
             )
           LIMIT 1 FOR UPDATE`,
          [candidate.scope, finalMemoryKey, content, ...sourceRows.map((message) => message.id)],
        ) : undefined);

    if (existing && existing.content === content) {
      await db.run(
        `UPDATE ai_memory SET confidence = GREATEST(confidence, ?), importance = GREATEST(importance, ?), updated_at = ? WHERE id = ?`,
        [confidence, importance, now, existing.id],
      );
      for (const message of sourceRows) {
        await db.run(
          `INSERT INTO ai_memory_evidence
           (memory_id, message_id, channel, sender, message_ts, excerpt, evidence_role, created_at)
           VALUES (?, ?, ?, ?, ?, ?, 'support', ?) ON CONFLICT(memory_id, message_id) DO NOTHING`,
          [existing.id, message.id, message.channel, message.sender, message.ts, message.text.slice(0, 600), now],
        );
      }
      return mapItem({ ...existing, confidence: Math.max(existing.confidence, confidence), importance: Math.max(existing.importance, importance), updated_at: now });
    }

    const id = `mem_${nanoid(16)}`;
    if (existing && versioned) {
      await db.run("UPDATE ai_memory SET status = 'superseded', updated_at = ? WHERE id = ?", [now, existing.id]);
    }
    await db.run(
      `INSERT INTO ai_memory
       (id, layer, scope, memory_key, subjects_json, speakers_json, content, category,
        confidence, importance, occurred_at, occurred_end_at, valid_from, valid_until,
        status, supersedes_id, metadata_json, embedding, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?)`,
      [
        id,
        candidate.layer,
        candidate.scope,
        finalMemoryKey,
        JSON.stringify([...new Set(candidate.subjects)]),
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
      ],
    );
    for (const message of sourceRows) {
      await db.run(
        `INSERT INTO ai_memory_evidence
         (memory_id, message_id, channel, sender, message_ts, excerpt, evidence_role, created_at)
         VALUES (?, ?, ?, ?, ?, ?, 'support', ?) ON CONFLICT(memory_id, message_id) DO NOTHING`,
        [id, message.id, message.channel, message.sender, message.ts, message.text.slice(0, 600), now],
      );
    }
    const row = await db.get<AiMemoryRow>("SELECT * FROM ai_memory WHERE id = ?", [id]);
    return row ? mapItem(row) : null;
  });
}

export async function listActiveMemoryContext(scope: string, limit = 80): Promise<MemoryItem[]> {
  const rows = await all<AiMemoryRow>(
    `SELECT * FROM ai_memory
     WHERE scope = ? AND status = 'active'
     ORDER BY CASE WHEN layer = 'event' THEN 1 ELSE 0 END, updated_at DESC LIMIT ?`,
    [scope, Math.max(1, Math.min(200, limit))],
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
    const vector = await embedOne(`${item.layer} ${item.category} ${item.subjects.join(" ")} ${item.content}`);
    if (!vector) continue;
    repaired += await run(
      "UPDATE ai_memory SET embedding = ?, updated_at = ? WHERE id = ? AND embedding IS NULL",
      [packVector(vector), Date.now(), item.id],
    );
  }
  return repaired;
}

export async function transitionMemory(input: {
  memoryId: string;
  scope: string;
  status: MemoryTransitionStatus;
  sourceMessageIds: string[];
  reason?: string;
}): Promise<boolean> {
  if (!input.sourceMessageIds.length) return false;
  const sourceRows = await all<MessageRow>(
    `SELECT * FROM messages
     WHERE id IN (${input.sourceMessageIds.map(() => "?").join(",")})
       AND kind = 'user' AND sender <> 'ai'
     ORDER BY ts ASC`,
    input.sourceMessageIds,
  );
  if (!sourceRows.length) return false;
  const now = Date.now();
  return transaction(async (db) => {
    const target = await db.get<AiMemoryRow>(
      "SELECT * FROM ai_memory WHERE id = ? AND scope = ? AND status = 'active' FOR UPDATE",
      [input.memoryId, input.scope],
    );
    if (!target) return false;
    for (const message of sourceRows) {
      await db.run(
        `INSERT INTO ai_memory_evidence
         (memory_id, message_id, channel, sender, message_ts, excerpt, evidence_role, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(memory_id, message_id) DO UPDATE SET evidence_role = EXCLUDED.evidence_role`,
        [target.id, message.id, message.channel, message.sender, message.ts, message.text.slice(0, 600), input.status, now],
      );
    }
    const metadata = { ...parseObject(target.metadata_json), transitionReason: input.reason ?? "", transitionedAt: now };
    await db.run(
      "UPDATE ai_memory SET status = ?, metadata_json = ?, updated_at = ? WHERE id = ?",
      [input.status, JSON.stringify(metadata), now, target.id],
    );
    return true;
  });
}

export async function invalidateMemoriesForRecalledMessage(messageId: string): Promise<number> {
  const now = Date.now();
  return transaction(async (db) => {
    const links = await db.all<{ memory_id: string }>(
      "SELECT memory_id FROM ai_memory_evidence WHERE message_id = ?",
      [messageId],
    );
    if (!links.length) return 0;
    await db.run(
      "UPDATE ai_memory_evidence SET evidence_role = 'retracted' WHERE message_id = ?",
      [messageId],
    );
    let invalidated = 0;
    for (const { memory_id: memoryId } of links) {
      const support = await db.get<{ count: number }>(
        `SELECT COUNT(*) AS count FROM ai_memory_evidence e
         JOIN messages msg ON msg.id = e.message_id
         WHERE e.memory_id = ? AND e.evidence_role = 'support'
           AND msg.kind = 'user' AND msg.sender <> 'ai'`,
        [memoryId],
      );
      if ((support?.count ?? 0) === 0) {
        invalidated += await db.run(
          "UPDATE ai_memory SET status = 'retracted', updated_at = ? WHERE id = ? AND status = 'active'",
          [now, memoryId],
        );
      }
    }
    return invalidated;
  });
}

export async function expireMemoryStates(now = Date.now()): Promise<number> {
  return run(
    `UPDATE ai_memory SET status = 'expired', updated_at = ?
     WHERE layer IN ('state', 'plan') AND status = 'active'
       AND valid_until IS NOT NULL AND valid_until <= ?`,
    [now, now],
  );
}

export async function reconcileMemoryLifecycle(now = Date.now()): Promise<{ expired: number; retracted: number }> {
  const expired = await expireMemoryStates(now);
  const retracted = await run(
    `UPDATE ai_memory m SET status = 'retracted', updated_at = ?
     WHERE m.status = 'active'
       AND COALESCE(m.metadata_json::jsonb ->> 'legacyReviewed', 'false') <> 'true'
       AND NOT EXISTS (
       SELECT 1 FROM ai_memory_evidence e
       JOIN messages msg ON msg.id = e.message_id
       WHERE e.memory_id = m.id AND e.evidence_role = 'support'
         AND msg.kind = 'user' AND msg.sender <> 'ai'
     )`,
    [now],
  );
  return { expired, retracted };
}

export interface SearchMemoryInput {
  query: string;
  layers: MemoryLayer[];
  scopes: string[];
  subjects?: string[];
  from?: number;
  to?: number;
  limit?: number;
}

export async function searchMemory(input: SearchMemoryInput): Promise<Array<MemoryItem & { score: number; lexicalHits: number; evidenceCount: number }>> {
  if (!input.layers.length || !input.scopes.length) return [];
  await expireMemoryStates();
  const clauses = [
    `layer IN (${input.layers.map(() => "?").join(",")})`,
    `scope IN (${input.scopes.map(() => "?").join(",")})`,
    "status = 'active'",
  ];
  const params: Array<string | number> = [...input.layers, ...input.scopes];
  if (input.from) { clauses.push("COALESCE(occurred_at, valid_from, created_at) >= ?"); params.push(input.from); }
  if (input.to) { clauses.push("COALESCE(occurred_at, valid_from, created_at) <= ?"); params.push(input.to); }
  const rows = await all<AiMemoryRow>(
    `SELECT * FROM ai_memory WHERE ${clauses.join(" AND ")} ORDER BY updated_at DESC LIMIT 10000`,
    params,
  );
  const subjects = new Set(input.subjects ?? []);
  const filtered = rows.map(mapItem).filter((item) => subjects.size === 0 || item.subjects.some((subject) => subjects.has(subject)) || item.subjects.includes("both"));
  const vector = input.query.trim() && embeddingEnabled() ? await embedOne(input.query) : null;
  const terms = searchTerms(input.query);
  const evidenceRows = filtered.length
    ? await all<{ memory_id: string; count: number }>(
        `SELECT memory_id, COUNT(*) AS count FROM ai_memory_evidence
         WHERE evidence_role = 'support'
           AND memory_id IN (${filtered.map(() => "?").join(",")}) GROUP BY memory_id`,
        filtered.map((item) => item.id),
      )
    : [];
  const evidenceCounts = new Map(evidenceRows.map((row) => [row.memory_id, row.count]));
  const scored = filtered.map((item) => {
    const lower = item.content.toLowerCase();
    const hits = terms.reduce((count, term) => count + (lower.includes(term) ? 1 : 0), 0);
    const score = vector && item.vector ? similarity(vector, item.vector) : 0;
    return { ...item, score, lexicalHits: hits, evidenceCount: evidenceCounts.get(item.id) ?? 0 };
  });
  return scored
    .filter((item) => !input.query.trim() || item.lexicalHits > 0 || item.score >= 0.38)
    .sort((a, b) => b.lexicalHits - a.lexicalHits || b.score - a.score || b.importance - a.importance || b.updatedAt - a.updatedAt)
    .slice(0, Math.max(1, Math.min(20, input.limit ?? 8)));
}

export async function memoryEvidence(memoryId: string, scopes: string[]): Promise<AiMemoryEvidenceRow[]> {
  if (!scopes.length) return [];
  return all<AiMemoryEvidenceRow>(
    `SELECT e.* FROM ai_memory_evidence e
     JOIN ai_memory m ON m.id = e.memory_id
     WHERE e.memory_id = ? AND m.scope IN (${scopes.map(() => "?").join(",")})
     ORDER BY e.message_ts ASC LIMIT 30`,
    [memoryId, ...scopes],
  );
}

export async function memoryStats(): Promise<Record<string, number>> {
  const rows = await all<{ layer: string; count: number }>(
    "SELECT layer, COUNT(*) AS count FROM ai_memory WHERE status = 'active' GROUP BY layer",
  );
  return Object.fromEntries(rows.map((row) => [row.layer, row.count]));
}

export interface MemoryDebugFilter {
  scopes: string[];
  layer?: MemoryLayer;
  status?: string;
  limit?: number;
}

export async function listMemoryForDebug(input: MemoryDebugFilter): Promise<Array<MemoryItem & { evidence: AiMemoryEvidenceRow[] }>> {
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
  if (!rows.length) return [];
  const evidence = await all<AiMemoryEvidenceRow>(
    `SELECT * FROM ai_memory_evidence
     WHERE memory_id IN (${rows.map(() => "?").join(",")})
     ORDER BY message_ts ASC`,
    rows.map((row) => row.id),
  );
  const grouped = new Map<string, AiMemoryEvidenceRow[]>();
  for (const item of evidence) grouped.set(item.memory_id, [...(grouped.get(item.memory_id) ?? []), item]);
  return rows.map((row) => ({ ...mapItem(row), evidence: grouped.get(row.id) ?? [] }));
}
