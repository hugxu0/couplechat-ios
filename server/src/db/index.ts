// PostgreSQL 数据层：pg 连接池 + SQLite 风格 `?` 占位符自动转 `$n`，
// 服务层的 SQL 基本原样保留。时间戳统一毫秒 BIGINT（int8 已配置解析为 number）。

import { Pool, types } from "pg";
import { config } from "../config";

// int8（BIGINT / COUNT()）默认返回字符串——这里全是毫秒时间戳和小计数，
// 都在 Number.MAX_SAFE_INTEGER 内，直接解析成 number，服务层不用改类型。
types.setTypeParser(20, (value) => Number(value));

let pool: Pool | null = null;

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

function conn(): Pool {
  if (!pool) throw new Error("Database is not initialized");
  return pool;
}

// SQLite 风格 `?` → PostgreSQL `$1..$n`（现有 SQL 里没有字面量问号，直接顺序替换）。
function toPg(sql: string): string {
  let index = 0;
  return sql.replace(/\?/g, () => `$${++index}`);
}

// pg 只认 Buffer 当二进制；Uint8Array（embedding 向量）在这里统一转换。
function normalizeParams(params: any[]): any[] {
  return params.map((p) => {
    if (p === undefined) return null;
    if (p instanceof Uint8Array && !Buffer.isBuffer(p)) {
      return Buffer.from(p.buffer, p.byteOffset, p.byteLength);
    }
    return p;
  });
}

export async function initDatabase() {
  pool = new Pool({
    connectionString: config.databaseUrl,
    max: 10,
  });
  // 尽早失败：连不上直接抛，而不是第一条查询才炸
  await pool.query("SELECT 1");
  await migrate();
}

export async function closeDatabase() {
  await pool?.end();
  pool = null;
}

export async function run(sql: string, params: any[] = []): Promise<void> {
  await conn().query(toPg(sql), normalizeParams(params));
}

export async function all<T extends object>(sql: string, params: any[] = []): Promise<T[]> {
  const result = await conn().query(toPg(sql), normalizeParams(params));
  return result.rows as T[];
}

export async function get<T extends object>(sql: string, params: any[] = []): Promise<T | undefined> {
  const rows = await all<T>(sql, params);
  return rows[0];
}

interface SchemaMigration {
  version: number;
  name: string;
  sql: string;
}

// 迁移必须只追加，已发布的版本号与 SQL 不再修改。
// 旧环境第一次升级时会安全地重跑 v1 中的 IF NOT EXISTS / ADD COLUMN IF NOT EXISTS，
// 然后写入台账；之后每次启动只执行尚未应用的版本。
const schemaMigrations: SchemaMigration[] = [
  {
    version: 1,
    name: "initial_schema",
    sql: `
    CREATE TABLE IF NOT EXISTS accounts (
      username TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      avatar TEXT NOT NULL DEFAULT '',
      bark_key TEXT,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
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
      ts BIGINT NOT NULL,
      client_id TEXT
    );

    CREATE UNIQUE INDEX IF NOT EXISTS messages_sender_client_id_idx
      ON messages(sender, client_id)
      WHERE client_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS messages_channel_ts_idx ON messages(channel, ts);

    CREATE TABLE IF NOT EXISTS read_receipts (
      channel TEXT NOT NULL,
      username TEXT NOT NULL,
      ts BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS read_receipts_channel_user_idx
      ON read_receipts(channel, username);

    CREATE TABLE IF NOT EXISTS shared_items (
      key TEXT PRIMARY KEY,
      value_json TEXT NOT NULL,
      updated_by TEXT NOT NULL,
      updated_at BIGINT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS personal_items (
      id TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      kind TEXT NOT NULL,
      scope TEXT NOT NULL DEFAULT 'personal',
      title TEXT NOT NULL,
      body_markdown TEXT NOT NULL DEFAULT '',
      due_at BIGINT,
      is_done INTEGER NOT NULL DEFAULT 0,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
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
      size BIGINT NOT NULL,
      created_at BIGINT NOT NULL
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
      embedding BYTEA,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      last_seen_at BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ai_facts_status_idx ON ai_facts(status);

    -- 事件卡片：每天把聊天按话题切成卡，独立向量化供语义召回
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
      embedding BYTEA,
      created_at BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ai_episodes_channel_date_idx ON ai_episodes(channel, date);

    -- AI 文档 KV：人物卡/关系卡/短期记忆/每日日记/心情/滚动摘要/任务完成标记
    CREATE TABLE IF NOT EXISTS ai_docs (
      key TEXT PRIMARY KEY,
      text TEXT NOT NULL,
      updated_at BIGINT NOT NULL
    );

    ALTER TABLE personal_items ADD COLUMN IF NOT EXISTS scope TEXT NOT NULL DEFAULT 'personal';
    `,
  },
];

async function migrate() {
  const database = conn();
  await database.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      applied_at BIGINT NOT NULL
    );
  `);

  const appliedResult = await database.query<{ version: number }>("SELECT version FROM schema_migrations");
  const appliedVersions = new Set(appliedResult.rows.map((row) => row.version));

  for (const migration of schemaMigrations) {
    if (appliedVersions.has(migration.version)) continue;

    const client = await database.connect();
    try {
      await client.query("BEGIN");
      await client.query(migration.sql);
      await client.query(
        "INSERT INTO schema_migrations (version, name, applied_at) VALUES ($1, $2, $3)",
        [migration.version, migration.name, Date.now()],
      );
      await client.query("COMMIT");
      console.info(`[db] 已应用迁移 v${migration.version}: ${migration.name}`);
    } catch (error) {
      await client.query("ROLLBACK").catch(() => undefined);
      throw new Error(
        `[db] 迁移 v${migration.version} (${migration.name}) 失败: ${error instanceof Error ? error.message : String(error)}`,
      );
    } finally {
      client.release();
    }
  }
}
