import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import dotenv from "dotenv";
import { nanoid } from "nanoid";

const aiEnvPath = path.resolve(".data/production-ai.env");
if (fs.existsSync(aiEnvPath)) {
  const remote = dotenv.parse(fs.readFileSync(aiEnvPath));
  for (const [key, value] of Object.entries(remote)) {
    if (/^(AI|EMBEDDING)_/.test(key) && process.env[key] === undefined) process.env[key] = value;
  }
}
dotenv.config();
process.env.DATABASE_URL ??= "postgres://couplechat:couplechat@127.0.0.1:55432/couplechat";
process.env.AI_MIGRATION_MODEL ??= "deepseek-v4-flash";

type SourceKind = "facts" | "episodes";
type MemoryLayer = "fact" | "event" | "plan" | "state" | "relationship" | "insight";

interface LegacySource {
  table: "ai_facts" | "ai_episodes";
  id: string;
  scopeHint: string;
  subjectHint: string[];
  categoryHint: string;
  occurredAt: number | null;
  searchText: string;
  payload: Record<string, unknown>;
}

interface ProposedMemory {
  sourceId?: unknown;
  layer?: string;
  subjects?: unknown;
  content?: unknown;
  category?: unknown;
  confidence?: unknown;
  importance?: unknown;
  occurredAt?: unknown;
  validUntil?: unknown;
  reason?: unknown;
}

interface SourceBatch {
  key: string;
  sources: LegacySource[];
}

const args = new Map(
  process.argv.slice(2).map((part) => {
    const [key, ...rest] = part.replace(/^--/, "").split("=");
    return [key, rest.length ? rest.join("=") : "true"];
  }),
);
const sourceKind = (args.get("source") ?? "facts") as SourceKind;
const limit = Math.max(1, Math.min(5000, Number(args.get("limit") ?? 20) || 20));
const publish = args.get("publish") === "true";
const publishAfter = args.get("publish-after") === "true";
const retry = args.get("retry") === "true";
const autoMode = args.get("auto") === "true";
const normalizeMode = args.get("normalize") === "true";
const normalizeHistoricalLayersMode = args.get("normalize-historical-layers") === "true";
const repairEmbeddingsMode = args.get("repair-embeddings") === "true";
const concurrency = Math.max(1, Math.min(48, Number(args.get("concurrency") ?? (sourceKind === "episodes" ? 24 : 6)) || 1));
const episodeBatchCardMax = Math.max(4, Math.min(20, Number(args.get("batch-card-max") ?? 10) || 10));
const approveId = args.get("approve");
const rejectId = args.get("reject");
const replaceRunId = args.get("replace-run");
if (!(["facts", "episodes"] as string[]).includes(sourceKind)) throw new Error("--source 只支持 facts 或 episodes");
if (replaceRunId && sourceKind !== "episodes") throw new Error("--replace-run 只支持 episodes");

async function main(): Promise<void> {
const db = await import("../src/db/index");
const { chat, extractJson } = await import("../src/ai/provider");
const { GEN } = await import("../src/ai/settings");
const { accounts, loadAccounts } = await import("../src/ai/accounts");
const { addMemory } = await import("../src/ai/memory/store");
const { embedOne, packVector } = await import("../src/ai/embeddings");
type MessageRow = import("../src/db/index").MessageRow;

function hash(value: string): string {
  return crypto.createHash("sha256").update(value).digest("hex").slice(0, 20);
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? [...new Set(value.map(String).map((item) => item.trim()).filter(Boolean))] : [];
}

function normalizedSourceId(value: unknown): string {
  return String(value ?? "").trim().replace(/^\[+|\]+$/g, "").trim();
}

function normalizedMemorySubject(value: unknown): string | null {
  const subject = String(value ?? "").trim();
  if (subject === "both") return subject;
  const account = accounts().find((item) => item.username === subject || item.name === subject);
  return account?.username ?? null;
}

function extractProposedMemories(raw: string): ProposedMemory[] {
  const parsed = extractJson<{ memories?: ProposedMemory[] }>(raw);
  if (Array.isArray(parsed?.memories)) return parsed.memories;
  const keyIndex = raw.indexOf('"memories"');
  const arrayStart = keyIndex >= 0 ? raw.indexOf("[", keyIndex) : -1;
  if (arrayStart < 0) return [];
  const memories: ProposedMemory[] = [];
  let objectStart = -1;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = arrayStart + 1; index < raw.length; index += 1) {
    const char = raw[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') {
      inString = true;
      continue;
    }
    if (char === "{") {
      if (depth === 0) objectStart = index;
      depth += 1;
      continue;
    }
    if (char !== "}" || depth === 0) continue;
    depth -= 1;
    if (depth !== 0 || objectStart < 0) continue;
    try {
      memories.push(JSON.parse(raw.slice(objectStart, index + 1)) as ProposedMemory);
    } catch {
      // 单个对象损坏时跳过，后续完整对象仍可继续恢复。
    }
    objectStart = -1;
  }
  return memories;
}

function numberOrNull(value: unknown): number | null {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function dayBounds(date: string): { start: number; end: number } {
  const start = new Date(`${date}T00:00:00+08:00`).getTime();
  return { start, end: start + 24 * 60 * 60 * 1000 };
}

function canonicalKey(layer: MemoryLayer, subjects: string[], category: string, content: string): string {
  const owners = [...subjects].sort().join("+") || "unknown";
  const normalized = content.toLowerCase().replace(/[\s，。！？、,.!?;；:：'"“”‘’（）()]/g, "");
  return `legacy.${layer}.${owners}.${category || "general"}.${hash(normalized)}`.slice(0, 160);
}

async function loadSources(kind: SourceKind): Promise<LegacySource[]> {
  if (kind === "facts") {
    const rows = await db.all<{
      id: string; subject: string; category: string; text: string; importance: number;
      status: string; created_at: number; updated_at: number;
    }>(
      `SELECT f.* FROM ai_facts f
       WHERE NOT EXISTS (
         SELECT 1 FROM ai_memory_import_candidates c
         WHERE c.source_table = 'ai_facts' AND c.source_id = f.id
           ${retry ? "AND c.status IN ('verified','approved','published')" : ""}
       )
       ORDER BY importance DESC, updated_at DESC LIMIT ?`,
      [limit],
    );
    return rows.map((row) => ({
      table: "ai_facts",
      id: row.id,
      scopeHint: "couple",
      subjectHint: [row.subject],
      categoryHint: row.category,
      occurredAt: null,
      searchText: row.text,
      payload: row,
    }));
  }

  if (replaceRunId) {
    const rows = await db.all<{
      id: string; channel: string; date: string; title: string; summary: string;
      key_points_json: string | null; mood: string | null; conclusion: string | null; created_at: number;
    }>(
      `WITH target_days AS (
         SELECT e.channel, e.date, MAX(e.created_at) AS newest
         FROM ai_episodes e
         JOIN ai_memory_import_candidates c ON c.source_id = e.id
         WHERE c.source_table = 'ai_episodes' AND c.run_id = ? AND c.status = 'verified'
         GROUP BY e.channel, e.date
         ORDER BY e.date DESC, newest DESC
         LIMIT ?
       )
       SELECT DISTINCT e.* FROM ai_episodes e
       JOIN target_days d ON d.channel = e.channel AND d.date = e.date
       JOIN ai_memory_import_candidates c ON c.source_id = e.id
       WHERE c.source_table = 'ai_episodes' AND c.run_id = ? AND c.status = 'verified'
       ORDER BY e.date DESC, e.channel ASC, e.created_at ASC`,
      [replaceRunId, limit, replaceRunId],
    );
    return rows.map((row) => ({
      table: "ai_episodes",
      id: row.id,
      scopeHint: row.channel,
      subjectHint: [],
      categoryHint: "event",
      occurredAt: dayBounds(row.date).start,
      searchText: [row.title, row.summary, row.key_points_json ?? "", row.conclusion ?? ""].join(" "),
      payload: row,
    }));
  }

  const rows = await db.all<{
    id: string; channel: string; date: string; title: string; summary: string;
    key_points_json: string | null; mood: string | null; conclusion: string | null; created_at: number;
  }>(
    `WITH pending_days AS (
       SELECT e.channel, e.date, MAX(e.created_at) AS newest
       FROM ai_episodes e
       WHERE NOT EXISTS (
         SELECT 1 FROM ai_memory_import_candidates c
         WHERE c.source_table = 'ai_episodes' AND c.source_id = e.id
           ${retry ? "AND c.status IN ('verified','approved','published')" : ""}
       )
       GROUP BY e.channel, e.date
       ORDER BY e.date DESC, newest DESC
       LIMIT ?
     )
     SELECT e.* FROM ai_episodes e
     JOIN pending_days d ON d.channel = e.channel AND d.date = e.date
     WHERE NOT EXISTS (
       SELECT 1 FROM ai_memory_import_candidates c
       WHERE c.source_table = 'ai_episodes' AND c.source_id = e.id
         ${retry ? "AND c.status IN ('verified','approved','published')" : ""}
     )
     ORDER BY e.date DESC, e.channel ASC, e.created_at ASC`,
    [limit],
  );
  return rows.map((row) => ({
    table: "ai_episodes",
    id: row.id,
    scopeHint: row.channel,
    subjectHint: [],
    categoryHint: "event",
    occurredAt: dayBounds(row.date).start,
    searchText: [row.title, row.summary, row.key_points_json ?? "", row.conclusion ?? ""].join(" "),
    payload: row,
  }));
}

function groupSources(sources: LegacySource[]): SourceBatch[] {
  if (sourceKind !== "episodes") {
    return sources.map((source) => ({ key: source.id, sources: [source] }));
  }
  const grouped = new Map<string, LegacySource[]>();
  for (const source of sources) {
    const date = String(source.payload.date ?? "unknown");
    const key = `${source.scopeHint}|${date}`;
    grouped.set(key, [...(grouped.get(key) ?? []), source]);
  }
  return [...grouped.entries()].flatMap(([key, batchSources]) => {
    const batches: SourceBatch[] = [];
    for (let index = 0; index < batchSources.length; index += episodeBatchCardMax) {
      const part = Math.floor(index / episodeBatchCardMax) + 1;
      const total = Math.ceil(batchSources.length / episodeBatchCardMax);
      batches.push({
        key: total > 1 ? `${key}#${part}/${total}` : key,
        sources: batchSources.slice(index, index + episodeBatchCardMax),
      });
    }
    return batches;
  });
}

function sourceScope(evidence: MessageRow[], fallback: string): string {
  const channels = [...new Set(evidence.map((row) => row.channel))];
  return channels.length === 1 ? channels[0] : fallback;
}

function fallbackLayer(source: LegacySource): MemoryLayer {
  if (source.table === "ai_episodes" || source.categoryHint === "event") return "event";
  if (source.categoryHint === "plan") return "plan";
  if (source.categoryHint === "observation") return "insight";
  if (source.categoryHint === "relationship" && source.subjectHint.includes("both")) return "relationship";
  return "fact";
}

async function storeLegacyReview(
  runId: string,
  source: LegacySource,
  reason: string,
  evidence: MessageRow[] = [],
  modelOutput = "",
): Promise<void> {
  const now = Date.now();
  const content = String(source.payload.text ?? source.payload.title ?? source.searchText).slice(0, 1200);
  const layer = fallbackLayer(source);
  const allowedSubjects = new Set([...accounts().map((account) => account.username), "both"]);
  const subjects = source.subjectHint.filter((subject) => allowedSubjects.has(subject));
  const speakers = [...new Set(evidence.map((row) => row.sender))];
  const evidenceIds = evidence.slice(0, 5).map((row) => row.id);
  const sourceHash = hash(`legacy-review:${layer}:${content}:${evidenceIds.join(",")}`);
  const id = `mic_${nanoid(16)}`;
  const status = autoMode ? "rejected" : "needs_review";
  const confidence = autoMode ? 0 : evidence.length ? 0.45 : 0.3;
  const inserted = await db.run(
    `INSERT INTO ai_memory_import_candidates
     (id, run_id, source_table, source_id, source_hash, layer, scope, memory_key,
      subjects_json, speakers_json, content, category, confidence, importance,
      status, review_reason, model_output_json, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(source_table, source_id, source_hash) DO NOTHING`,
    [
      id, runId, source.table, source.id, sourceHash, layer, sourceScope(evidence, source.scopeHint),
      canonicalKey(layer, subjects, source.categoryHint, content), JSON.stringify(subjects), JSON.stringify(speakers),
      content, source.categoryHint, confidence,
      Math.max(1, Math.min(5, Number(source.payload.importance) || 3)), status, reason,
      JSON.stringify({ raw: modelOutput, legacyOnly: evidence.length === 0 }), now, now,
    ],
  );
  if (!inserted) return;
  for (const messageId of evidenceIds) {
    await db.run(
      `INSERT INTO ai_memory_import_evidence (candidate_id, message_id, evidence_role, created_at)
       VALUES (?, ?, 'candidate', ?) ON CONFLICT DO NOTHING`,
      [id, messageId, now],
    );
  }
}

async function storeProposedMemory(
  runId: string,
  source: LegacySource,
  proposed: ProposedMemory,
  raw: string,
): Promise<boolean> {
  const layer = String(proposed.layer ?? "") as MemoryLayer;
  if (!(["fact", "event", "plan", "state", "relationship", "insight"] as string[]).includes(layer)) return false;
  const content = String(proposed.content ?? "").replace(/\s+/g, " ").trim().slice(0, 1200);
  if (content.length < 3) return false;
  const subjects = [...new Set(
    asStrings(proposed.subjects)
      .map(normalizedMemorySubject)
      .filter((subject): subject is string => Boolean(subject)),
  )];
  if (!subjects.length) return false;
  if (layer === "relationship" && !subjects.includes("both")) return false;
  const speakers: string[] = [];
  const category = String(proposed.category ?? source.categoryHint ?? "general").trim().slice(0, 80);
  const confidence = layer === "insight" ? 0.75 : 0.8;
  const importance = Math.max(1, Math.min(5, Math.round(Number(proposed.importance) || 3)));
  const status = autoMode ? "verified" : "needs_review";
  const scope = source.scopeHint;
  const sourceHash = hash(`${replaceRunId ? "normalized-v2|" : ""}${layer}|${subjects.sort().join("+")}|${category}|${content}`);
  const id = `mic_${nanoid(16)}`;
  const now = Date.now();
  const inserted = await db.run(
    `INSERT INTO ai_memory_import_candidates
     (id, run_id, source_table, source_id, source_hash, layer, scope, memory_key,
      subjects_json, speakers_json, content, category, confidence, importance,
      occurred_at, valid_until, status, review_reason, model_output_json, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(source_table, source_id, source_hash) DO NOTHING`,
    [
      id, runId, source.table, source.id, sourceHash, layer, scope,
      canonicalKey(layer, subjects, category, content), JSON.stringify(subjects), JSON.stringify(speakers),
      content, category, confidence, importance, numberOrNull(proposed.occurredAt) ?? source.occurredAt,
      numberOrNull(proposed.validUntil), status, String(proposed.reason ?? "由旧卡直接转换").slice(0, 600),
      JSON.stringify({ proposed, raw, conversion: "legacy_card_direct", legacySource: source.payload }), now, now,
    ],
  );
  return inserted > 0;
}

async function processSource(runId: string, source: LegacySource): Promise<number> {
  if (retry) {
    await db.run(
      "DELETE FROM ai_memory_import_candidates WHERE source_table = ? AND source_id = ? AND status NOT IN ('verified','approved','published')",
      [source.table, source.id],
    );
  }
  const system = [
    "你是旧记忆卡格式转换器。旧卡已经由旧系统阅读完整聊天上下文后生成，直接把卡片转换为当前结构，不搜索原文，不做真实性复核，也不判断是否值得保留。",
    "必须忠实保留旧卡的核心内容，可拆成最多四条原子记忆；不得添加卡片中没有的信息，也不得因为内容普通而输出空数组。",
    "layer 只能是 fact/event/plan/state/relationship/insight：稳定资料用 fact，已发生经历用 event，未来安排用 plan，短期近况用 state，共同关系约定用 relationship，归纳性观察用 insight。",
    "relationship 只保存双方明确表达的关系身份、共同约定或边界，subjects 必须包含 both。单人的性格、沟通倾向或行为模式只能归为 insight，不能归为 relationship。",
    "subjects 只能使用给定 username 或 both。根据卡片中的姓名、称谓和行为归属判断实际主体；共同经历使用 both，不能留空。",
    "confidence 固定输出 0.8。importance 只表示内容重要程度，1~5，不影响是否保留。occurredAt 和 validUntil 只能是毫秒时间戳或 null。",
    "只输出严格 JSON，不要 markdown。格式：{\"memories\":[{\"layer\":\"event\",\"subjects\":[\"xu\"],\"content\":\"...\",\"category\":\"general\",\"confidence\":0.8,\"importance\":2,\"occurredAt\":null,\"validUntil\":null,\"reason\":\"由旧卡直接转换\"}]}",
  ].join("\n");
  const user = [
    `可用账号：${accounts().map((account) => `${account.username}=${account.name}`).join("，")}`,
    `旧记忆卡：\n${JSON.stringify(source.payload)}`,
  ].join("\n\n");
  const raw = await chat({ profile: "migration", system, user, gen: GEN.migration });
  const parsed = extractJson<{ memories?: ProposedMemory[] }>(raw);
  if (!parsed?.memories?.length) {
    await storeLegacyReview(
      runId,
      source,
      raw ? "模型没有生成有效结构" : "模型调用失败",
      [],
      raw ?? "",
    );
    return autoMode ? 0 : 1;
  }

  let stored = 0;
  for (const proposed of parsed.memories.slice(0, 8)) {
    if (await storeProposedMemory(runId, source, proposed, raw ?? "")) stored += 1;
  }
  if (!stored) {
    await storeLegacyReview(runId, source, "模型输出未通过结构校验", [], raw ?? "");
    return autoMode ? 0 : 1;
  }
  return stored;
}

function compactEpisode(source: LegacySource): string {
  const payload = source.payload;
  return [
    `sourceId=${source.id}`,
    `标题=${String(payload.title ?? "")}`,
    `摘要=${String(payload.summary ?? "")}`,
    payload.key_points_json ? `要点=${String(payload.key_points_json)}` : "",
    payload.mood ? `情绪=${String(payload.mood)}` : "",
    payload.conclusion ? `结论=${String(payload.conclusion)}` : "",
  ].filter(Boolean).join("\n");
}

async function recoverEpisodeBatch(
  runId: string,
  batch: SourceBatch,
): Promise<{ stored: number; remaining: LegacySource[] }> {
  if (!retry || !batch.sources.length) return { stored: 0, remaining: batch.sources };
  const rows = await db.all<{ source_id: string; model_output_json: string }>(
    `SELECT source_id, model_output_json FROM ai_memory_import_candidates
     WHERE source_table = 'ai_episodes' AND status IN ('rejected','needs_review')
       AND source_id IN (${batch.sources.map(() => "?").join(",")})`,
    batch.sources.map((source) => source.id),
  );
  const rawOutputs = new Set<string>();
  for (const row of rows) {
    try {
      const wrapper = JSON.parse(row.model_output_json) as { raw?: unknown };
      const raw = String(wrapper.raw ?? "").trim();
      if (raw) rawOutputs.add(raw);
    } catch {
      // 旧候选可能没有可恢复的模型原文，稍后正常重跑。
    }
  }
  const sourceById = new Map(batch.sources.map((source) => [source.id, source]));
  const recovered = new Set<string>();
  let stored = 0;
  for (const raw of rawOutputs) {
    for (const proposed of extractProposedMemories(raw)) {
      const source = sourceById.get(normalizedSourceId(proposed.sourceId));
      if (!source) continue;
      if (await storeProposedMemory(runId, source, proposed, raw)) {
        stored += 1;
        recovered.add(source.id);
      }
    }
  }
  for (const sourceId of recovered) {
    await db.run(
      `DELETE FROM ai_memory_import_candidates
       WHERE source_table = 'ai_episodes' AND source_id = ?
         AND status IN ('rejected','needs_review')`,
      [sourceId],
    );
  }
  return { stored, remaining: batch.sources.filter((source) => !recovered.has(source.id)) };
}

async function processEpisodeBatch(runId: string, batch: SourceBatch): Promise<number> {
  const recovered = await recoverEpisodeBatch(runId, batch);
  let stored = recovered.stored;
  batch = { ...batch, sources: recovered.remaining };
  if (!batch.sources.length) return stored;
  if (retry) {
    for (const source of batch.sources) {
      await db.run(
        "DELETE FROM ai_memory_import_candidates WHERE source_table = ? AND source_id = ? AND status NOT IN ('verified','approved','published')",
        [source.table, source.id],
      );
    }
  }
  const date = String(batch.sources[0]?.payload.date ?? "");
  const system = [
    "你把同一天的一组旧事件卡转换为当前原子记忆。旧卡可信，不搜索原文，不复核，不遗漏普通内容。",
    "每条记忆必须带输入中的 sourceId；只能归属于一张旧卡。默认每张卡生成一条，确有不同记忆层时最多拆两条；不合并不同 sourceId 的内容，不添加卡片外信息。",
    "layer：稳定资料=fact，已发生经历=event，未来安排=plan，短期近况=state，共同约定或边界=relationship，归纳观察=insight。",
    "subjects 只能使用给定 username 或 both；共同经历用 both；relationship 必须包含 both。",
    "无需输出 confidence、reason、occurredAt。importance 为 1~5；category 使用简短类别。",
    "只输出严格 JSON，不要 markdown：{\"memories\":[{\"sourceId\":\"旧卡id\",\"layer\":\"event\",\"subjects\":[\"both\"],\"content\":\"...\",\"category\":\"general\",\"importance\":2}]}。",
  ].join("\n");
  const user = [
    `账号：${accounts().map((account) => `${account.username}=${account.name}`).join("，")}`,
    `频道：${batch.sources[0]?.scopeHint ?? "couple"}；日期：${date}`,
    batch.sources.map(compactEpisode).join("\n\n"),
  ].join("\n\n");
  const raw = await chat({ profile: "migration", system, user, gen: GEN.migration });
  const sourceById = new Map(batch.sources.map((source) => [source.id, source]));
  const storedBySource = new Map(batch.sources.map((source) => [source.id, 0]));
  const maxMemories = Math.max(2, batch.sources.length * 2);

  for (const proposed of extractProposedMemories(raw ?? "").slice(0, maxMemories)) {
    const source = sourceById.get(normalizedSourceId(proposed.sourceId));
    if (!source) continue;
    if (await storeProposedMemory(runId, source, proposed, raw ?? "")) {
      storedBySource.set(source.id, (storedBySource.get(source.id) ?? 0) + 1);
    }
  }

  for (const source of batch.sources) {
    const sourceStored = storedBySource.get(source.id) ?? 0;
    if (sourceStored) {
      stored += sourceStored;
      continue;
    }
    await storeLegacyReview(
      runId,
      source,
      raw ? "批量模型未为该卡生成有效结构" : "批量模型调用失败",
      [],
      raw ?? "",
    );
    if (!autoMode) stored += 1;
  }
  return stored;
}

async function processBatch(runId: string, batch: SourceBatch): Promise<number> {
  return sourceKind === "episodes"
    ? processEpisodeBatch(runId, batch)
    : processSource(runId, batch.sources[0]);
}

async function publishVerified(): Promise<void> {
  const rows = await db.all<{
    id: string; layer: MemoryLayer; scope: string; memory_key: string; subjects_json: string;
    speakers_json: string; content: string; category: string; confidence: number; importance: number;
    occurred_at: number | null; valid_until: number | null; source_table: "ai_facts" | "ai_episodes";
  }>(
    `SELECT * FROM ai_memory_import_candidates
     WHERE status IN ('verified','approved') AND published_memory_id IS NULL
     ORDER BY created_at ASC LIMIT ?`,
    [limit],
  );
  let published = 0;
  let recovered = 0;
  let errors = 0;
  let processed = 0;
  let nextIndex = 0;
  const worker = async () => {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= rows.length) return;
      const row = rows[index];
      try {
        const existing = await db.get<{ id: string }>(
          `SELECT id FROM ai_memory
           WHERE metadata_json::jsonb ->> 'importCandidateId' = ?
           ORDER BY created_at DESC LIMIT 1`,
          [row.id],
        );
        if (existing) {
          await db.run(
            "UPDATE ai_memory_import_candidates SET status = 'published', published_memory_id = ?, updated_at = ? WHERE id = ?",
            [existing.id, Date.now(), row.id],
          );
          recovered += 1;
        } else {
          const evidence = await db.all<{ message_id: string }>(
            "SELECT message_id FROM ai_memory_import_evidence WHERE candidate_id = ? ORDER BY message_id",
            [row.id],
          );
          const memory = await addMemory({
            layer: row.layer,
            scope: row.scope,
            memoryKey: row.memory_key,
            subjects: JSON.parse(row.subjects_json),
            speakers: JSON.parse(row.speakers_json),
            content: row.content,
            category: row.category,
            confidence: row.confidence,
            importance: row.importance,
            occurredAt: row.occurred_at,
            validUntil: row.valid_until,
            metadata: {
              importCandidateId: row.id,
              importedFromLegacy: true,
              legacyReviewed: evidence.length === 0,
              provenance: evidence.length
                ? "legacy_with_candidate_messages"
                : row.source_table === "ai_episodes" ? "legacy_event_card" : "legacy_manual_approval",
              evidencePolicy: "trusted_legacy_card",
            },
            sourceMessageIds: evidence.map((item) => item.message_id),
            allowWithoutEvidence: evidence.length === 0,
          });
          if (!memory) throw new Error("正式 Memory 写入返回空");
          await db.run(
            "UPDATE ai_memory_import_candidates SET status = 'published', published_memory_id = ?, updated_at = ? WHERE id = ?",
            [memory.id, Date.now(), row.id],
          );
          published += 1;
        }
      } catch (error) {
        errors += 1;
        console.warn(`[memory-import] publish ${row.id} failed: ${error instanceof Error ? error.message : error}`);
      }
      processed += 1;
      if (processed % 50 === 0 || processed === rows.length) {
        console.log(`[memory-import] publish progress=${processed}/${rows.length} published=${published} recovered=${recovered} errors=${errors}`);
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, Math.max(1, rows.length)) }, () => worker()));
  console.log(`[memory-import] published=${published}/${rows.length} recovered=${recovered} errors=${errors}`);
  if (errors) throw new Error(`发布有 ${errors} 条失败，可安全重跑`);
}

async function normalizeEpisodeCandidates(): Promise<void> {
  const rows = await db.all<{
    id: string; layer: MemoryLayer; subjects_json: string; content: string; category: string;
    model_output_json: string; summary: string; published_memory_id: string | null;
  }>(
    `SELECT c.id, c.layer, c.subjects_json, c.content, c.category, c.model_output_json,
            c.published_memory_id, e.summary
     FROM ai_memory_import_candidates c
     JOIN ai_episodes e ON e.id = c.source_id
     WHERE c.source_table = 'ai_episodes' AND c.status IN ('verified','approved','published')
       AND (LENGTH(c.content) < 12 OR c.subjects_json::jsonb @> '["si","xu"]'::jsonb)`,
  );
  let changed = 0;
  for (const row of rows) {
    let subjects = asStrings(JSON.parse(row.subjects_json));
    const normalizations: string[] = [];
    if (subjects.includes("si") && subjects.includes("xu")) {
      subjects = ["both"];
      normalizations.push("joint_subjects_to_both");
    }
    let content = row.content.replace(/\s+/g, " ").trim();
    const summary = row.summary.replace(/\s+/g, " ").trim();
    if (content.length < 12 && summary.length > content.length) {
      content = summary.slice(0, 1200);
      normalizations.push("short_content_from_legacy_summary");
    }
    if (!normalizations.length) continue;
    let metadata: Record<string, unknown> = {};
    try {
      const parsed = JSON.parse(row.model_output_json);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) metadata = parsed;
    } catch {
      // 保留空对象并记录确定性归一化来源。
    }
    const sourceHash = hash(`normalized-v3|${row.layer}|${subjects.sort().join("+")}|${row.category}|${content}`);
    await db.run(
      `UPDATE ai_memory_import_candidates
       SET source_hash = ?, memory_key = ?, subjects_json = ?, content = ?, model_output_json = ?, updated_at = ?
       WHERE id = ?`,
      [
        sourceHash,
        canonicalKey(row.layer, subjects, row.category, content),
        JSON.stringify(subjects),
        content,
        JSON.stringify({ ...metadata, deterministicNormalizations: normalizations }),
        Date.now(),
        row.id,
      ],
    );
    if (row.published_memory_id) {
      await db.run(
        `UPDATE ai_memory
         SET memory_key = ?, subjects_json = ?, content = ?, updated_at = ?
         WHERE id = ?`,
        [canonicalKey(row.layer, subjects, row.category, content), JSON.stringify(subjects), content, Date.now(), row.published_memory_id],
      );
    }
    changed += 1;
  }
  console.log(`[memory-import] normalized=${changed}/${rows.length}`);
}

async function repairPublishedEmbeddings(): Promise<void> {
  const rows = await db.all<{
    id: string; layer: MemoryLayer; category: string; subjects_json: string; content: string;
  }>(
    `SELECT m.id, m.layer, m.category, m.subjects_json, m.content
     FROM ai_memory m
     JOIN ai_memory_import_candidates c ON c.id = m.metadata_json::jsonb ->> 'importCandidateId'
     WHERE c.status = 'published' AND m.embedding IS NULL
     ORDER BY m.created_at ASC LIMIT ?`,
    [limit],
  );
  let repaired = 0;
  let failed = 0;
  let nextIndex = 0;
  const worker = async () => {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= rows.length) return;
      const row = rows[index];
      const subjects = asStrings(JSON.parse(row.subjects_json));
      const vector = await embedOne(`${row.layer} ${row.category} ${subjects.join(" ")} ${row.content}`);
      if (!vector) {
        failed += 1;
        continue;
      }
      await db.run("UPDATE ai_memory SET embedding = ?, updated_at = ? WHERE id = ?", [packVector(vector), Date.now(), row.id]);
      repaired += 1;
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, Math.max(1, rows.length)) }, () => worker()));
  console.log(`[memory-import] embedding-repair repaired=${repaired}/${rows.length} failed=${failed}`);
  if (failed) throw new Error(`仍有 ${failed} 条 embedding 修复失败，可稍后安全重跑`);
}

async function normalizeHistoricalLayers(): Promise<void> {
  const rows = await db.all<{
    id: string; published_memory_id: string; layer: "plan" | "state"; subjects_json: string;
    content: string; category: string; occurred_at: number | null; model_output_json: string;
    memory_metadata_json: string; source_table: "ai_facts" | "ai_episodes";
  }>(
    `SELECT c.id, c.published_memory_id, c.layer, c.subjects_json, c.content, c.category,
            c.occurred_at, c.model_output_json, c.source_table,
            m.metadata_json AS memory_metadata_json
     FROM ai_memory_import_candidates c
     JOIN ai_memory m ON m.id = c.published_memory_id
     WHERE c.status = 'published' AND c.layer IN ('plan','state')`,
  );
  let changed = 0;
  for (const row of rows) {
    const subjects = asStrings(JSON.parse(row.subjects_json));
    const isHistoricalSchedule = /提醒|值日|日期|下周|明天|后天|\d{1,2}月\d{1,2}日/.test(row.content);
    const targetLayer: MemoryLayer = row.source_table === "ai_episodes" || isHistoricalSchedule
      ? "event"
      : row.layer === "state" && row.category === "preference"
        ? "fact"
        : row.layer === "state"
          ? "insight"
          : "relationship";
    const memoryKey = canonicalKey(targetLayer, subjects, row.category, row.content);
    const sourceHash = hash(`historical-layer-v2|${targetLayer}|${subjects.sort().join("+")}|${row.category}|${row.content}`);
    let candidateMetadata: Record<string, unknown> = {};
    let memoryMetadata: Record<string, unknown> = {};
    try { candidateMetadata = JSON.parse(row.model_output_json); } catch { /* 使用空对象 */ }
    try { memoryMetadata = JSON.parse(row.memory_metadata_json); } catch { /* 使用空对象 */ }
    const normalization = { from: row.layer, to: targetLayer, source: row.source_table };
    await db.run(
      `UPDATE ai_memory_import_candidates
       SET source_hash = ?, layer = ?, memory_key = ?, occurred_at = ?, valid_from = NULL,
           valid_until = NULL, model_output_json = ?, updated_at = ? WHERE id = ?`,
      [
        sourceHash,
        targetLayer,
        memoryKey,
        targetLayer === "event" ? row.occurred_at : null,
        JSON.stringify({ ...candidateMetadata, historicalLayerNormalization: normalization }),
        Date.now(),
        row.id,
      ],
    );
    await db.run(
      `UPDATE ai_memory
       SET layer = ?, memory_key = ?, occurred_at = ?,
           valid_from = NULL, valid_until = NULL, metadata_json = ?, embedding = NULL, updated_at = ?
       WHERE id = ?`,
      [
        targetLayer,
        memoryKey,
        targetLayer === "event" ? row.occurred_at : null,
        JSON.stringify({ ...memoryMetadata, historicalLayerNormalization: normalization }),
        Date.now(),
        row.published_memory_id,
      ],
    );
    changed += 1;
  }
  console.log(`[memory-import] historical-layer-normalized=${changed}/${rows.length}`);
}

await db.initDatabase();
try {
  await loadAccounts();
  if (approveId || rejectId) {
    const id = approveId ?? rejectId!;
    const status = approveId ? "approved" : "rejected";
    const changed = await db.run(
      "UPDATE ai_memory_import_candidates SET status = ?, updated_at = ? WHERE id = ? AND status IN ('needs_review','verified')",
      [status, Date.now(), id],
    );
    console.log(`[memory-import] ${status} id=${id} changed=${changed}`);
  } else if (normalizeMode) {
    await normalizeEpisodeCandidates();
  } else if (normalizeHistoricalLayersMode) {
    await normalizeHistoricalLayers();
  } else if (repairEmbeddingsMode) {
    await repairPublishedEmbeddings();
  } else if (publish) {
    await publishVerified();
  } else {
    const now = Date.now();
    const staleBefore = now - 10 * 60 * 1000;
    await db.run(
      `UPDATE ai_memory_import_runs
       SET status = 'interrupted', finished_at = ?, updated_at = ?
       WHERE status = 'running' AND updated_at < ?`,
      [now, now, staleBefore],
    );
    const activeRun = await db.get<{ id: string }>(
      "SELECT id FROM ai_memory_import_runs WHERE status = 'running' ORDER BY created_at DESC LIMIT 1",
    );
    if (activeRun) throw new Error(`已有迁移正在运行：${activeRun.id}`);
    const model = process.env.AI_MIGRATION_MODEL ?? "deepseek-v4-flash";
    const runId = `mir_${nanoid(16)}`;
    await db.run(
      `INSERT INTO ai_memory_import_runs
       (id, source, model, status, options_json, created_at, updated_at)
       VALUES (?, ?, ?, 'running', ?, ?, ?)`,
      [runId, sourceKind, model, JSON.stringify({
        limit,
        limitUnit: sourceKind === "episodes" ? "channel_days" : "cards",
        retry,
        autoMode,
        concurrency,
        episodeBatchCardMax: sourceKind === "episodes" ? episodeBatchCardMax : undefined,
        publishAfter,
        batchMode: sourceKind === "episodes" ? "channel_date" : "single",
        replaceRunId: replaceRunId ?? undefined,
      }), now, now],
    );
    const sources = await loadSources(sourceKind);
    const batches = groupSources(sources);
    let candidateCount = 0;
    let errors = 0;
    let processed = 0;
    let processedBatches = 0;
    let nextIndex = 0;
    const worker = async () => {
      while (true) {
        const index = nextIndex;
        nextIndex += 1;
        if (index >= batches.length) return;
        const batch = batches[index];
        try {
          const count = await processBatch(runId, batch);
          candidateCount += count;
        } catch (error) {
          errors += batch.sources.length;
          console.warn(`[memory-import] batch=${batch.key} failed: ${error instanceof Error ? error.message : error}`);
        }
        processed += batch.sources.length;
        processedBatches += 1;
        console.log(`[memory-import] cards=${processed}/${sources.length} batches=${processedBatches}/${batches.length} batch=${batch.key} candidates=${candidateCount}`);
        await db.run(
          `UPDATE ai_memory_import_runs
           SET processed_count = ?, candidate_count = ?, error_count = ?, updated_at = ? WHERE id = ?`,
          [processed, candidateCount, errors, Date.now(), runId],
        );
      }
    };
    await Promise.all(Array.from({ length: Math.min(concurrency, Math.max(1, batches.length)) }, () => worker()));
    await db.run(
      `UPDATE ai_memory_import_runs SET status = ?, finished_at = ?, updated_at = ? WHERE id = ?`,
      [errors ? "completed_with_errors" : "completed", Date.now(), Date.now(), runId],
    );
    if (replaceRunId) {
      const superseded = await db.run(
        `UPDATE ai_memory_import_candidates old
         SET status = 'superseded', updated_at = ?
         WHERE old.run_id = ? AND old.status = 'verified'
           AND EXISTS (
             SELECT 1 FROM ai_memory_import_candidates fresh
             WHERE fresh.run_id = ? AND fresh.source_id = old.source_id AND fresh.status = 'verified'
           )`,
        [Date.now(), replaceRunId, runId],
      );
      console.log(`[memory-import] replace-run=${replaceRunId} superseded=${superseded}`);
    }
    console.log(`[memory-import] run=${runId} cards=${sources.length} batches=${batches.length} candidates=${candidateCount} errors=${errors}`);
    if (publishAfter && errors === 0) await publishVerified();
  }
} finally {
  await db.closeDatabase();
}
}

void main().catch((error) => {
  console.error(`[memory-import] fatal: ${error instanceof Error ? error.stack ?? error.message : error}`);
  process.exitCode = 1;
});
