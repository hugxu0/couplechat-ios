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

function persist() {
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
  persist();
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

    CREATE TABLE IF NOT EXISTS uploads (
      id TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      path TEXT NOT NULL,
      url TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      size INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    );
  `);
}
