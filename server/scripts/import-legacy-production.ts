// 将旧网页后端 chat.db + uploads + ai_docs 转换到当前 PostgreSQL schema。
// 这是“源端全量为准”的生产迁移：保留 accounts（密码/Bark/TOKEN_SECRET 均不动），
// 替换消息、已读、共享状态、提醒备忘、上传索引和全部 AI 记忆数据。
//
// 必须在停写并完成 pg_dump 后运行：
//   IMPORT_LEGACY_REPLACE=YES \
//   LEGACY_SQLITE_PATH=/root/import/chat.db \
//   LEGACY_AI_DOCS_PATH=/root/import/ai_docs \
//   LEGACY_UPLOADS_PATH=/opt/couplechat-ios/server/uploads \
//   npx tsx scripts/import-legacy-production.ts

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import "dotenv/config";
import { config } from "../src/config";
import { closeDatabase, initDatabase, transaction, type DatabaseTransaction } from "../src/db";

const sqlitePath = process.env.LEGACY_SQLITE_PATH ?? "";
const aiDocsPath = process.env.LEGACY_AI_DOCS_PATH ?? "";
const uploadsPath = process.env.LEGACY_UPLOADS_PATH ?? config.uploadDir;
// 12 列 messages × 2,000 = 24,000 个绑定参数，远低于 PostgreSQL 单语句上限；
// 相比 200 行一批，可显著降低低配生产机上的网络/解析往返开销。
const BATCH_SIZE = 2_000;

type LegacyRow = Record<string, unknown>;

function requiredPath(label: string, value: string): string {
  if (!value || !fs.existsSync(value)) throw new Error(`${label} 不存在: ${value || "(空)"}`);
  return path.resolve(value);
}

function mapIdentity(value: unknown): string {
  const text = String(value ?? "");
  if (text === "alice") return "xu";
  if (text === "bob") return "si";
  if (text === "ai:alice") return "ai:xu";
  if (text === "ai:bob") return "ai:si";
  return text;
}

function remapJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(remapJson);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
      out[mapIdentity(key)] = remapJson(child);
    }
    return out;
  }
  return typeof value === "string" ? mapIdentity(value) : value;
}

function remapJsonText(value: unknown): string | null {
  const text = String(value ?? "").trim();
  if (!text) return null;
  try {
    return JSON.stringify(remapJson(JSON.parse(text)));
  } catch {
    return text;
  }
}

function asNumber(value: unknown, fallback = Date.now()): number {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function mimeFor(filename: string): string {
  const ext = path.extname(filename).toLowerCase();
  return ({
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
    ".gif": "image/gif", ".webp": "image/webp", ".heic": "image/heic",
    ".mp4": "video/mp4", ".mov": "video/quicktime", ".webm": "video/webm",
    ".m4a": "audio/m4a", ".mp3": "audio/mpeg", ".wav": "audio/wav",
    ".pdf": "application/pdf", ".zip": "application/zip",
  } as Record<string, string>)[ext] ?? "application/octet-stream";
}

function filenameFromUrl(value: unknown): string | null {
  const text = String(value ?? "");
  const marker = "/uploads/";
  const index = text.lastIndexOf(marker);
  if (index < 0) return null;
  const filename = decodeURIComponent(text.slice(index + marker.length).split(/[?#]/, 1)[0]);
  return filename && path.basename(filename) === filename ? filename : null;
}

async function insertRows(
  db: DatabaseTransaction,
  table: string,
  columns: string[],
  rows: unknown[][],
): Promise<void> {
  for (let offset = 0; offset < rows.length; offset += BATCH_SIZE) {
    const chunk = rows.slice(offset, offset + BATCH_SIZE);
    const placeholders = chunk.map(() => `(${columns.map(() => "?").join(",")})`).join(",");
    await db.run(
      `INSERT INTO ${table} (${columns.join(",")}) VALUES ${placeholders} ON CONFLICT DO NOTHING`,
      chunk.flat(),
    );
    if (rows.length >= 10_000) process.stdout.write(`\r  ${table}: ${Math.min(offset + chunk.length, rows.length)}/${rows.length}`);
  }
  if (rows.length >= 10_000) process.stdout.write("\n");
}

async function insertLegacyMessages(db: DatabaseTransaction, sqlite: DatabaseSync): Promise<{
  count: number;
  mediaByFilename: Map<string, { messageId: string; owner: string; ts: number }>;
}> {
  const total = Number((sqlite.prepare("SELECT COUNT(*) AS n FROM messages").get() as LegacyRow).n);
  const select = sqlite.prepare("SELECT * FROM messages ORDER BY ts, id LIMIT ? OFFSET ?");
  const mediaByFilename = new Map<string, { messageId: string; owner: string; ts: number }>();
  for (let offset = 0; offset < total; offset += BATCH_SIZE) {
    const rows = select.all(BATCH_SIZE, offset) as LegacyRow[];
    const values = rows.map((row) => {
      const id = String(row.id);
      const owner = mapIdentity(row.sender);
      const ts = asNumber(row.ts);
      const filename = filenameFromUrl(row.url);
      if (filename && !mediaByFilename.has(filename)) mediaByFilename.set(filename, { messageId: id, owner, ts });
      return [
        id, mapIdentity(row.channel), owner, String(row.senderName ?? ""), String(row.kind ?? "user"),
        String(row.type ?? "text"), String(row.text ?? ""), row.url ? String(row.url) : null,
        remapJsonText(row.reply), remapJsonText(row.meta), ts, null,
      ];
    });
    await insertRows(db, "messages", [
      "id", "channel", "sender", "sender_name", "kind", "type", "text", "url",
      "reply_json", "meta_json", "ts", "client_id",
    ], values);
    process.stdout.write(`\r  messages: ${Math.min(offset + rows.length, total)}/${total}`);
  }
  process.stdout.write("\n");
  return { count: total, mediaByFilename };
}

function readShared(sqlite: DatabaseSync): LegacyRow[] {
  return sqlite.prepare("SELECT key, value, ts FROM shared ORDER BY key").all() as LegacyRow[];
}

function collectUsage(sharedRows: LegacyRow[]): {
  avatars: Set<string>;
  stickers: Set<string>;
  avatarByUser: Map<string, string>;
} {
  const avatars = new Set<string>();
  const stickers = new Set<string>();
  const avatarByUser = new Map<string, string>();
  for (const row of sharedRows) {
    try {
      const value = remapJson(JSON.parse(String(row.value))) as Record<string, unknown> | unknown[];
      if (row.key === "avatars" && value && !Array.isArray(value)) {
        for (const [username, url] of Object.entries(value)) {
          const filename = filenameFromUrl(url);
          if (filename) avatars.add(filename);
          if (typeof url === "string") avatarByUser.set(username, url);
        }
      }
      if (row.key === "stickers" && Array.isArray(value)) {
        for (const sticker of value as Array<Record<string, unknown>>) {
          const filename = filenameFromUrl(sticker.url);
          if (filename) stickers.add(filename);
        }
      }
    } catch {
      // 原值仍会原样进入 shared_items；这里只跳过用途分类。
    }
  }
  return { avatars, stickers, avatarByUser };
}

function personalItems(sharedRows: LegacyRow[]): unknown[][] {
  const rows: unknown[][] = [];
  for (const source of sharedRows) {
    if (source.key !== "reminders" && source.key !== "memos") continue;
    let items: Array<Record<string, unknown>> = [];
    try {
      const parsed = remapJson(JSON.parse(String(source.value)));
      if (Array.isArray(parsed)) items = parsed as Array<Record<string, unknown>>;
    } catch {
      continue;
    }
    for (const item of items) {
      const body = String(item.text ?? item.title ?? "").trim();
      if (!body) continue;
      const firstLine = body.split(/\r?\n/, 1)[0].replace(/^#+\s*/, "").slice(0, 120) || "备忘录";
      const updatedAt = asNumber(source.ts);
      const dueAt = source.key === "reminders" ? asNumber(item.ts, NaN) : null;
      rows.push([
        String(item.id ?? `legacy_${crypto.randomUUID()}`), mapIdentity(item.owner || "xu"),
        source.key === "reminders" ? "reminder" : "memo", "shared", firstLine,
        source.key === "memos" ? body : "", Number.isFinite(dueAt) ? dueAt : null,
        item.done ? 1 : 0, asNumber(item.createdAt ?? item.created_at, updatedAt), updatedAt,
      ]);
    }
  }
  return rows;
}

function collectAiDocs(sqlite: DatabaseSync, docsRoot: string): Map<string, { text: string; ts: number }> {
  const docs = new Map<string, { text: string; ts: number }>();
  const set = (key: string, text: string, ts: number, overwrite = true) => {
    if (text.trim() && (overwrite || !docs.has(key))) docs.set(key, { text: text.trim(), ts });
  };
  const readFile = (relative: string): { text: string; ts: number } | null => {
    const file = path.join(docsRoot, relative);
    if (!fs.existsSync(file)) return null;
    const stat = fs.statSync(file);
    return { text: fs.readFileSync(file, "utf8"), ts: Math.floor(stat.mtimeMs) };
  };

  const profiles: Array<[string, string[]]> = [
    ["profile:xu", ["memory/profile-alice.md", "memory/profile-xu.md"]],
    ["profile:si", ["memory/profile-bob.md", "memory/profile-si.md"]],
    ["relationship", ["memory/relationship.md"]],
    ["short-term", ["memory/short-term.md"]],
  ];
  for (const [key, candidates] of profiles) {
    for (const relative of candidates) {
      const file = readFile(relative);
      if (file) { set(key, file.text, file.ts); break; }
    }
  }

  const dailyDir = path.join(docsRoot, "daily");
  if (fs.existsSync(dailyDir)) {
    for (const filename of fs.readdirSync(dailyDir)) {
      const match = /^(\d{4}-\d{2}-\d{2})\.daju-detail\.md$/.exec(filename);
      if (!match) continue;
      const file = readFile(path.join("daily", filename));
      if (!file) continue;
      set(`digest:${match[1]}`, file.text, file.ts);
      set(`done:digest:${match[1]}`, "1", file.ts);
    }
  }

  const cache = sqlite.prepare("SELECT k, text, ts FROM daily_cache ORDER BY ts").all() as LegacyRow[];
  const finalizedDiaries = new Set<string>();
  for (const row of cache) {
    const key = String(row.k);
    const text = String(row.text ?? "");
    const ts = asNumber(row.ts);
    set(`legacy-cache:${mapIdentity(key)}`, text, ts);
    let match = /^mood:(\d{4}-\d{2}-\d{2})$/.exec(key);
    if (match) set(`mood:${match[1]}`, text, ts);
    match = /^rec:(\d{4}-\d{2}-\d{2})$/.exec(key);
    if (match) set(`recommend:${match[1]}`, text, ts);
    match = /^today-summary:(\d{4}-\d{2}-\d{2})$/.exec(key);
    if (match && !finalizedDiaries.has(match[1])) set(`diary:${match[1]}`, text, ts);
    match = /^yesterday-summary:(\d{4}-\d{2}-\d{2})$/.exec(key);
    if (match) {
      finalizedDiaries.add(match[1]);
      set(`diary:${match[1]}`, text, ts);
      set(`done:diary:${match[1]}`, "1", ts);
    }
    match = /^sessionSummary:(.+)$/.exec(key);
    if (match) set(`session-summary:${mapIdentity(match[1])}`, text, ts);
    match = /^kb-built:(.+):(\d{4}-\d{2}-\d{2})$/.exec(key);
    if (match) set(`done:episodes:${mapIdentity(match[1])}:${match[2]}`, "1", ts);
  }

  const latestTs = asNumber((sqlite.prepare("SELECT MAX(ts) AS ts FROM messages").get() as LegacyRow).ts);
  set("cursor:fact-scan", String(latestTs), latestTs);
  return docs;
}

export async function importLegacyProduction(): Promise<void> {
  if (process.env.IMPORT_LEGACY_REPLACE !== "YES") {
    throw new Error("这是替换式导入；确认已停写并完成备份后设置 IMPORT_LEGACY_REPLACE=YES");
  }
  const source = requiredPath("LEGACY_SQLITE_PATH", sqlitePath);
  const docsRoot = requiredPath("LEGACY_AI_DOCS_PATH", aiDocsPath);
  const uploadRoot = requiredPath("LEGACY_UPLOADS_PATH", uploadsPath);
  const sqlite = new DatabaseSync(source, { readOnly: true });
  const tables = new Set((sqlite.prepare("SELECT name FROM sqlite_master WHERE type='table'").all() as LegacyRow[]).map((r) => String(r.name)));
  for (const required of ["messages", "shared", "read_state", "memory_facts", "knowledge_cards", "daily_cache"]) {
    if (!tables.has(required)) throw new Error(`旧库缺少表 ${required}`);
  }

  const sharedRows = readShared(sqlite);
  const usage = collectUsage(sharedRows);
  const docs = collectAiDocs(sqlite, docsRoot);
  await initDatabase();
  let messageCount = 0;
  let uploadCount = 0;
  await transaction(async (db) => {
    // TRUNCATE 在事务内可回滚，且会立即清空旧索引页；比逐表 DELETE 后顶着
    // 38 万条 dead tuples 重建快得多。accounts/schema_migrations 明确保留。
    await db.run(
      `TRUNCATE TABLE
       message_attachments, ai_memory_import_evidence, ai_memory_evidence,
       ai_memory_import_candidates, ai_memory_import_runs, ai_memory, ai_memory_cursor,
       ai_runtime_state, uploads, messages, read_receipts, shared_items, personal_items,
       ai_facts, ai_episodes, ai_docs`,
    );

    const importedMessages = await insertLegacyMessages(db, sqlite);
    messageCount = importedMessages.count;

    const sharedValues = sharedRows.map((row) => [
      String(row.key), remapJsonText(row.value) ?? "null", "migration", asNumber(row.ts),
    ]);
    await insertRows(db, "shared_items", ["key", "value_json", "updated_by", "updated_at"], sharedValues);
    await insertRows(db, "personal_items", [
      "id", "owner", "kind", "scope", "title", "body_markdown", "due_at", "is_done", "created_at", "updated_at",
    ], personalItems(sharedRows));

    const receipts = sqlite.prepare("SELECT username, ts FROM read_state").all() as LegacyRow[];
    await insertRows(db, "read_receipts", ["channel", "username", "ts", "updated_at"],
      receipts.map((row) => ["couple", mapIdentity(row.username), asNumber(row.ts), asNumber(row.ts)]));

    const facts = sqlite.prepare("SELECT * FROM memory_facts ORDER BY created_ts, id").all() as LegacyRow[];
    await insertRows(db, "ai_facts", [
      "id", "subject", "category", "text", "importance", "status", "embedding", "created_at", "updated_at", "last_seen_at",
    ], facts.map((row) => [
      row.id, mapIdentity(row.subject), row.category, row.text, asNumber(row.importance, 3), row.status || "active",
      row.embedding ?? null, asNumber(row.created_ts), asNumber(row.updated_ts), asNumber(row.last_seen_ts),
    ]));

    const episodes = sqlite.prepare("SELECT * FROM knowledge_cards ORDER BY card_date, topic_index, id").all() as LegacyRow[];
    await insertRows(db, "ai_episodes", [
      "id", "channel", "date", "title", "summary", "key_points_json", "mood", "conclusion", "keywords", "embedding", "created_at",
    ], episodes.map((row) => [
      row.id, mapIdentity(row.channel), row.card_date, row.title,
      String(row.summary || row.body_markdown || ""), row.key_points || "[]", row.mood || null,
      row.conclusion || null, row.keywords || null, row.embedding ?? null, asNumber(row.updatedAt),
    ]));

    await insertRows(db, "ai_docs", ["key", "text", "updated_at"],
      [...docs.entries()].map(([key, value]) => [key, value.text, value.ts]));

    const uploadRows: unknown[][] = [];
    for (const entry of fs.readdirSync(uploadRoot, { withFileTypes: true })) {
      if (!entry.isFile()) continue;
      const filename = entry.name;
      const file = path.join(uploadRoot, filename);
      const stat = fs.statSync(file);
      const media = importedMessages.mediaByFilename.get(filename);
      const leadingTs = Number(/^([0-9]{13})-/.exec(filename)?.[1]);
      const purpose = media ? "message" : usage.avatars.has(filename) ? "avatar" : usage.stickers.has(filename) ? "sticker" : "legacy";
      const id = `legacy_${crypto.createHash("sha256").update(filename).digest("hex").slice(0, 24)}`;
      uploadRows.push([
        id, media?.owner ?? "xu", file, `${config.publicBaseURL.replace(/\/$/, "")}/uploads/${encodeURIComponent(filename)}`,
        mimeFor(filename), stat.size, Number.isFinite(leadingTs) ? leadingTs : Math.floor(stat.mtimeMs),
        media?.messageId ?? null, purpose,
      ]);
    }
    uploadCount = uploadRows.length;
    await insertRows(db, "uploads", ["id", "owner", "path", "url", "mime_type", "size", "created_at", "message_id", "purpose"], uploadRows);

    for (const [username, avatar] of usage.avatarByUser) {
      await db.run("UPDATE accounts SET avatar = ?, updated_at = ? WHERE username = ?", [avatar, Date.now(), username]);
    }
  });

  sqlite.close();
  await closeDatabase();
  console.log(`导入完成 messages=${messageCount} uploads=${uploadCount} shared=${sharedRows.length} ai_docs=${docs.size}`);
}

if (require.main === module) {
  importLegacyProduction().catch(async (error) => {
    console.error("旧生产数据导入失败:", error instanceof Error ? error.message : error);
    await closeDatabase().catch(() => undefined);
    process.exit(1);
  });
}
