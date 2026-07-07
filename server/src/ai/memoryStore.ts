// 记忆存取层：ai_facts / ai_episodes / ai_docs 三张表的全部读写。
// 业务规则（分类归一、主语归一、embedding 查重）也在这里——上层只关心「存一条事实」。

import { nanoid } from "nanoid";
import { all, get, run, type AiDocRow, type AiEpisodeRow, type AiFactRow } from "../db";
import { listPublicAccounts } from "../auth/accounts";
import { embedOne, embeddingEnabled, packVector, similarity, unpackVector } from "./embeddings";
import { MEMORY } from "./params";

// ─── 分类 ────────────────────────────────────────────────────────────────

export const CATEGORIES = [
  { key: "profile", label: "基本信息" },
  { key: "preference", label: "喜好与口味" },
  { key: "habit", label: "习惯与作息" },
  { key: "health", label: "健康与身体" },
  { key: "boundary", label: "雷区与边界" },
  { key: "relationship", label: "关系与沟通" },
  { key: "plan", label: "约定与安排" },
  { key: "event", label: "人物与事件" },
  { key: "observation", label: "大橘的观察" },
] as const;

const CATEGORY_KEYS = new Set<string>(CATEGORIES.map((c) => c.key));

export function normalizeCategory(raw: unknown): string {
  const c = String(raw ?? "").trim();
  return CATEGORY_KEYS.has(c) ? c : "observation";
}

// ─── 账号缓存（主语归一 / 展示名） ────────────────────────────────────────

interface AccountInfo {
  username: string;
  name: string;
}

let accountsCache: AccountInfo[] = [];

export async function loadAccounts(): Promise<AccountInfo[]> {
  if (accountsCache.length === 0) {
    accountsCache = (await listPublicAccounts()).map((a) => ({ username: a.username, name: a.name }));
  }
  return accountsCache;
}

export function accounts(): AccountInfo[] {
  return accountsCache;
}

export function normalizeSubject(raw: unknown): string {
  const s = String(raw ?? "").trim();
  if (!s || s === "both" || s === "两人" || s === "我们") return "both";
  if (s === "daju" || s === "大橘") return "daju";
  const match = accountsCache.find((a) => a.username === s || a.name === s);
  return match ? match.username : "both";
}

export function subjectLabel(subject: string): string {
  if (subject === "both") return "两人";
  if (subject === "daju") return "大橘";
  return accountsCache.find((a) => a.username === subject)?.name ?? subject;
}

// ─── 事实库 ──────────────────────────────────────────────────────────────

export interface Fact {
  id: string;
  subject: string;
  category: string;
  text: string;
  importance: number;
  status: string;
  vector: Float32Array | null;
}

function mapFact(row: AiFactRow): Fact {
  return {
    id: row.id,
    subject: row.subject,
    category: row.category,
    text: row.text,
    importance: row.importance,
    status: row.status,
    vector: unpackVector(row.embedding),
  };
}

export function factLine(f: Fact): string {
  return `[${subjectLabel(f.subject)}] ${f.text}`;
}

export function listFacts(filter: { status?: string; minImportance?: number; limit?: number } = {}): Fact[] {
  const clauses: string[] = [];
  const params: (string | number)[] = [];
  if (filter.status) {
    clauses.push("status = ?");
    params.push(filter.status);
  }
  if (filter.minImportance) {
    clauses.push("importance >= ?");
    params.push(filter.minImportance);
  }
  const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
  params.push(filter.limit ?? 500);
  return all<AiFactRow>(
    `SELECT * FROM ai_facts ${where} ORDER BY importance DESC, last_seen_at DESC LIMIT ?`,
    params,
  ).map(mapFact);
}

export interface AddFactInput {
  subject: unknown;
  text: unknown;
  category: unknown;
  importance: unknown;
  status?: "fresh" | "active";
}

// 存一条事实：归一化 → embedding 查重（相似 ≥ factDupScore 只刷新 last_seen_at）→ 入库。
export async function addFact(input: AddFactInput): Promise<{ ok: boolean; deduped: boolean }> {
  const text = String(input.text ?? "").replace(/\s+/g, " ").trim().slice(0, MEMORY.factTextMax);
  if (text.length < MEMORY.factTextMin) return { ok: false, deduped: false };
  const subject = normalizeSubject(input.subject);
  const category = normalizeCategory(input.category);
  const importanceNum = Math.round(Number(input.importance));
  const importance = Number.isFinite(importanceNum) ? Math.max(1, Math.min(5, importanceNum)) : 3;
  const now = Date.now();

  let vector: Float32Array | null = null;
  if (embeddingEnabled()) {
    vector = await embedOne(`${subjectLabel(subject)} ${text}`);
    if (vector) {
      for (const existing of listFacts({ limit: 2000 })) {
        if (existing.vector && similarity(vector, existing.vector) >= MEMORY.factDupScore) {
          run("UPDATE ai_facts SET last_seen_at = ? WHERE id = ?", [now, existing.id]);
          return { ok: true, deduped: true };
        }
      }
    }
  } else {
    // 无 embedding 时退化为字面查重。
    const dup = get<AiFactRow>("SELECT * FROM ai_facts WHERE text = ? AND subject = ?", [text, subject]);
    if (dup) {
      run("UPDATE ai_facts SET last_seen_at = ? WHERE id = ?", [now, dup.id]);
      return { ok: true, deduped: true };
    }
  }

  run(
    `INSERT INTO ai_facts (id, subject, category, text, importance, status, embedding, created_at, updated_at, last_seen_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      `fact_${nanoid(12)}`,
      subject,
      category,
      text,
      importance,
      input.status ?? "fresh",
      vector ? packVector(vector) : null,
      now,
      now,
      now,
    ],
  );
  return { ok: true, deduped: false };
}

export async function updateFact(
  id: string,
  patch: { text?: string; category?: string; subject?: string; importance?: number; status?: string },
) {
  const existing = get<AiFactRow>("SELECT * FROM ai_facts WHERE id = ?", [id]);
  if (!existing) return;
  const text = patch.text?.trim() ? patch.text.trim().slice(0, MEMORY.factTextMax) : existing.text;
  // 正文变了要重算向量，否则召回还按旧语义打分。
  let embedding = existing.embedding;
  if (text !== existing.text && embeddingEnabled()) {
    const v = await embedOne(text);
    if (v) embedding = packVector(v);
  }
  run(
    `UPDATE ai_facts SET subject = ?, category = ?, text = ?, importance = ?, status = ?, embedding = ?, updated_at = ?
     WHERE id = ?`,
    [
      patch.subject ? normalizeSubject(patch.subject) : existing.subject,
      patch.category ? normalizeCategory(patch.category) : existing.category,
      text,
      patch.importance ?? existing.importance,
      patch.status ?? existing.status,
      embedding,
      Date.now(),
      id,
    ],
  );
}

export function deleteFact(id: string) {
  run("DELETE FROM ai_facts WHERE id = ?", [id]);
}

// ─── 事件卡片 ────────────────────────────────────────────────────────────

export interface Episode {
  id: string;
  channel: string;
  date: string;
  title: string;
  summary: string;
  keyPoints: string[];
  mood: string;
  conclusion: string;
  keywords: string;
  vector: Float32Array | null;
}

function mapEpisode(row: AiEpisodeRow): Episode {
  let keyPoints: string[] = [];
  try {
    const parsed = JSON.parse(row.key_points_json ?? "[]");
    if (Array.isArray(parsed)) keyPoints = parsed.map((p) => String(p));
  } catch {
    /* 忽略 */
  }
  return {
    id: row.id,
    channel: row.channel,
    date: row.date,
    title: row.title,
    summary: row.summary,
    keyPoints,
    mood: row.mood ?? "",
    conclusion: row.conclusion ?? "",
    keywords: row.keywords ?? "",
    vector: unpackVector(row.embedding),
  };
}

export function listEpisodes(channel?: string): Episode[] {
  if (channel) {
    return all<AiEpisodeRow>("SELECT * FROM ai_episodes WHERE channel = ?", [channel]).map(mapEpisode);
  }
  return all<AiEpisodeRow>("SELECT * FROM ai_episodes", []).map(mapEpisode);
}

export interface AddEpisodeInput {
  channel: string;
  date: string;
  title: string;
  summary: string;
  keyPoints: string[];
  mood: string;
  conclusion: string;
  keywords: string;
}

export async function addEpisode(input: AddEpisodeInput) {
  let embedding: Uint8Array | null = null;
  if (embeddingEnabled()) {
    const v = await embedOne(
      [input.title, input.summary, ...input.keyPoints, input.keywords].filter(Boolean).join("\n"),
    );
    if (v) embedding = packVector(v);
  }
  run(
    `INSERT INTO ai_episodes (id, channel, date, title, summary, key_points_json, mood, conclusion, keywords, embedding, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      `ep_${nanoid(12)}`,
      input.channel,
      input.date,
      input.title.slice(0, 80),
      input.summary.slice(0, 300),
      JSON.stringify(input.keyPoints.slice(0, 6)),
      input.mood.slice(0, 100),
      input.conclusion.slice(0, 120),
      input.keywords.slice(0, 200),
      embedding,
      Date.now(),
    ],
  );
}

export function deleteEpisodesByDate(channel: string, date: string) {
  run("DELETE FROM ai_episodes WHERE channel = ? AND date = ?", [channel, date]);
}

// ─── 文档 KV ─────────────────────────────────────────────────────────────
// key 约定：profile:<username> / relationship / short-term / mood:<date> /
//           digest:<date> / session-summary:<channel> / done:<job>:<date> / cursor:<name>

export function getDoc(key: string): string {
  return get<AiDocRow>("SELECT * FROM ai_docs WHERE key = ?", [key])?.text ?? "";
}

export function setDoc(key: string, text: string) {
  run(
    `INSERT INTO ai_docs (key, text, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at`,
    [key, text, Date.now()],
  );
}

// 每日任务完成标记（幂等重试的依据；每步独立标记，一步失败不拖累其他步）。
export function isJobDone(job: string, date: string): boolean {
  return getDoc(`done:${job}:${date}`) === "1";
}

export function markJobDone(job: string, date: string) {
  setDoc(`done:${job}:${date}`, "1");
}
