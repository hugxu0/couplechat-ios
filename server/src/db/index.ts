import fs from "node:fs";
import path from "node:path";
import initSqlJs, { type Database, type SqlValue } from "sql.js";
import { config } from "../config";

let sqlite: Database | null = null;
let dbPath = "";

export interface AccountRow {
  username: string;
  display_name: string;
  password_hash: string;
  avatar: string;
  bark_key: string | null;
  created_at: number;
  updated_at: number;
}

export interface MessageRow {
  id: string;
  channel: string;
  sender: string;
  sender_name: string;
  kind: string;
  type: string;
  text: string;
  url: string | null;
  reply_json: string | null;
  meta_json: string | null;
  ts: number;
  client_id: string | null;
}

export interface ReadReceiptRow {
  channel: string;
  username: string;
  ts: number;
  updated_at: number;
}

export interface SharedItemRow {
  key: string;
  value_json: string;
  updated_by: string;
  updated_at: number;
}

export interface PersonalItemRow {
  id: string;
  owner: string;
  kind: string;
  scope: string;
  title: string;
  body_markdown: string;
  due_at: number | null;
  is_done: number;
  created_at: number;
  updated_at: number;
}

export interface AiFactRow {
  id: string;
  subject: string;
  category: string;
  text: string;
  importance: number;
  status: string;
  embedding: Uint8Array | null;
  created_at: number;
  updated_at: number;
  last_seen_at: number;
}

export interface AiEpisodeRow {
  id: string;
  channel: string;
  date: string;
  title: string;
  summary: string;
  key_points_json: string | null;
  mood: string | null;
  conclusion: string | null;
  keywords: string | null;
  embedding: Uint8Array | null;
  created_at: number;
}

export interface AiDocRow {
  key: string;
  text: string;
  updated_at: number;
}

export interface UploadRow {
  id: string;
  owner: string;
  path: string;
  url: string;
  mime_type: string;
  size: number;
  created_at: number;
}

function conn() {
  if (!sqlite) throw new Error("Database is not initialized");
  return sqlite;
}

let persistTimer: ReturnType<typeof setTimeout> | null = null;
let pendingPersist = false;

function persist() {
  pendingPersist = true;
  if (persistTimer) return;
  persistTimer = setTimeout(() => {
    persistTimer = null;
    if (!pendingPersist) return;
    pendingPersist = false;
    doPersist();
  }, 100);
}

export function flushSync() {
  if (persistTimer) { clearTimeout(persistTimer); persistTimer = null; }
  if (pendingPersist) { pendingPersist = false; doPersist(); }
}

function doPersist() {
  const database = conn();
  const data = Buffer.from(database.export());
  const tmp = `${dbPath}.tmp`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, dbPath);
}

export async function initDatabase() {
  fs.mkdirSync(config.dataDir, { recursive: true });
  dbPath = path.join(config.dataDir, "couplechat.sqlite");

  const SQL = await initSqlJs();
  if (fs.existsSync(dbPath)) {
    sqlite = new SQL.Database(fs.readFileSync(dbPath));
  } else {
    sqlite = new SQL.Database();
  }

  migrate();
  doPersist();
}

export function run(sql: string, params: SqlValue[] = [], shouldPersist = true) {
  conn().run(sql, params);
  if (shouldPersist) persist();
}

export function all<T extends object>(sql: string, params: SqlValue[] = []): T[] {
  const stmt = conn().prepare(sql, params);
  const rows: T[] = [];
  try {
    while (stmt.step()) {
      rows.push(stmt.getAsObject() as unknown as T);
    }
  } finally {
    stmt.free();
  }
  return rows;
}

export function get<T extends object>(sql: string, params: SqlValue[] = []): T | undefined {
  return all<T>(sql, params)[0];
}

export function transaction(fn: () => void) {
  const database = conn();
  database.run("BEGIN");
  try {
    fn();
    database.run("COMMIT");
    persist();
  } catch (error) {
    database.run("ROLLBACK");
    throw error;
  }
}

function migrate() {
  const database = conn();
  database.run(`
    CREATE TABLE IF NOT EXISTS accounts (
      username TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      avatar TEXT NOT NULL DEFAULT '',
      bark_key TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY,
      channel TEXT NOT NULL,
      sender TEXT NOT NULL,
      sender_name TEXT NOT NULL,
      kind TEXT NOT NULL,
      type TEXT NOT NULL,
      text TEXT NOT NULL DEFAULT '',
      url TEXT,
      reply_json TEXT,
      meta_json TEXT,
      ts INTEGER NOT NULL,
      client_id TEXT
    );

    CREATE UNIQUE INDEX IF NOT EXISTS messages_sender_client_id_idx
      ON messages(sender, client_id)
      WHERE client_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS messages_channel_ts_idx ON messages(channel, ts);

    CREATE TABLE IF NOT EXISTS read_receipts (
      channel TEXT NOT NULL,
      username TEXT NOT NULL,
      ts INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS read_receipts_channel_user_idx
      ON read_receipts(channel, username);

    CREATE TABLE IF NOT EXISTS shared_items (
      key TEXT PRIMARY KEY,
      value_json TEXT NOT NULL,
      updated_by TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS personal_items (
      id TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      kind TEXT NOT NULL,
      scope TEXT NOT NULL DEFAULT 'personal',
      title TEXT NOT NULL,
      body_markdown TEXT NOT NULL DEFAULT '',
      due_at INTEGER,
      is_done INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS personal_items_owner_kind_updated_idx
      ON personal_items(owner, kind, scope, updated_at DESC);
    CREATE INDEX IF NOT EXISTS personal_items_owner_due_idx
      ON personal_items(owner, due_at);

    CREATE TABLE IF NOT EXISTS uploads (
      id TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      path TEXT NOT NULL,
      url TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      size INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    );

    -- ── AI 记忆系统 ──────────────────────────────────────────────
    -- 长期事实库：一行 = 一条稳定事实，随行携带归一化 embedding，
    -- 问答时按话题向量召回。status: fresh（白天新提取）→ active（夜间收口转正）。
    CREATE TABLE IF NOT EXISTS ai_facts (
      id TEXT PRIMARY KEY,
      subject TEXT NOT NULL,
      category TEXT NOT NULL,
      text TEXT NOT NULL,
      importance INTEGER NOT NULL DEFAULT 3,
      status TEXT NOT NULL DEFAULT 'fresh',
      embedding BLOB,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ai_facts_status_idx ON ai_facts(status);

    -- 事件卡片：每天把聊天按话题切成卡，独立向量化供语义召回
    -- （取代旧后端的 knowledge_cards + chunk_embeddings 双索引）。
    CREATE TABLE IF NOT EXISTS ai_episodes (
      id TEXT PRIMARY KEY,
      channel TEXT NOT NULL,
      date TEXT NOT NULL,
      title TEXT NOT NULL,
      summary TEXT NOT NULL DEFAULT '',
      key_points_json TEXT,
      mood TEXT,
      conclusion TEXT,
      keywords TEXT,
      embedding BLOB,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ai_episodes_channel_date_idx ON ai_episodes(channel, date);

    -- AI 文档 KV：人物卡/关系卡/短期记忆/每日日记/心情/滚动摘要/任务完成标记，
    -- 全部走这一张表（取代旧后端的 markdown 文件 + daily_cache 混用）。
    CREATE TABLE IF NOT EXISTS ai_docs (
      key TEXT PRIMARY KEY,
      text TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );
  `);

  // Idempotent migration for scope column (added post-initial schema)
  try {
    database.run("ALTER TABLE personal_items ADD COLUMN scope TEXT NOT NULL DEFAULT 'personal'");
  } catch {
    // column already exists — safe to ignore
  }
}
