// 一次性迁移：.data/couplechat.sqlite → PostgreSQL。
// 幂等：全部 INSERT ... ON CONFLICT DO NOTHING，重复跑不会产生脏数据。
// 流式分页读取（LIMIT/OFFSET），单批只处理少量行——目标机器可能只有几百 MB 内存，
// 一次性 `.all()` 整表读进内存（几十万条消息）会被系统 OOM 杀掉。
//
// 用法（在 server/ 目录下）：
//   DATABASE_URL=postgres://couplechat:xxx@localhost:5432/couplechat npx tsx scripts/migrate-sqlite-to-postgres.ts
// 可选环境变量 SQLITE_PATH 指定源库路径（默认 .data/couplechat.sqlite）。

import path from "node:path";
import fs from "node:fs";
import { DatabaseSync } from "node:sqlite";
import "dotenv/config";
import { initDatabase, closeDatabase, run } from "../src/db";

const sqlitePath = process.env.SQLITE_PATH ?? path.resolve(process.cwd(), ".data", "couplechat.sqlite");

interface TableSpec {
  name: string;
  columns: string[];
  // 单批读取+写入的行数；大表（messages/ai_episodes 带 embedding blob）用小批次控内存。
  batchSize?: number;
}

const TABLES: TableSpec[] = [
  { name: "accounts", columns: ["username", "display_name", "password_hash", "avatar", "bark_key", "created_at", "updated_at"] },
  { name: "messages", columns: ["id", "channel", "sender", "sender_name", "kind", "type", "text", "url", "reply_json", "meta_json", "ts", "client_id"], batchSize: 200 },
  { name: "read_receipts", columns: ["channel", "username", "ts", "updated_at"] },
  { name: "shared_items", columns: ["key", "value_json", "updated_by", "updated_at"] },
  { name: "personal_items", columns: ["id", "owner", "kind", "scope", "title", "body_markdown", "due_at", "is_done", "created_at", "updated_at"] },
  { name: "uploads", columns: ["id", "owner", "path", "url", "mime_type", "size", "created_at"] },
  { name: "ai_facts", columns: ["id", "subject", "category", "text", "importance", "status", "embedding", "created_at", "updated_at", "last_seen_at"], batchSize: 100 },
  { name: "ai_episodes", columns: ["id", "channel", "date", "title", "summary", "key_points_json", "mood", "conclusion", "keywords", "embedding", "created_at"], batchSize: 100 },
  { name: "ai_docs", columns: ["key", "text", "updated_at"] },
];

const DEFAULT_BATCH = 500;

function tableExists(sqlite: DatabaseSync, name: string): boolean {
  const row = sqlite
    .prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
    .get(name);
  return Boolean(row);
}

async function migrateTable(sqlite: DatabaseSync, spec: TableSpec): Promise<number> {
  if (!tableExists(sqlite, spec.name)) {
    console.log(`  跳过 ${spec.name}（源表不存在）`);
    return 0;
  }

  const total = (sqlite.prepare(`SELECT COUNT(*) AS c FROM "${spec.name}"`).get() as { c: number }).c;
  if (!total) {
    console.log(`  ${spec.name}: 0 行`);
    return 0;
  }

  const batchSize = spec.batchSize ?? DEFAULT_BATCH;
  const cols = spec.columns;
  const colList = cols.map((c) => `"${c}"`).join(", ");
  const selectStmt = sqlite.prepare(`SELECT ${colList} FROM "${spec.name}" LIMIT ? OFFSET ?`);
  const placeholderRow = `(${cols.map(() => "?").join(", ")})`;

  let migrated = 0;
  for (let offset = 0; offset < total; offset += batchSize) {
    // 每批独立从 SQLite 分页读取，用完立刻丢弃引用——不在内存里囤整张表。
    const chunk = selectStmt.all(batchSize, offset) as Record<string, unknown>[];
    if (!chunk.length) break;

    const placeholders = chunk.map(() => placeholderRow).join(", ");
    const params = chunk.flatMap((row) => cols.map((c) => row[c] ?? null));
    await run(
      `INSERT INTO ${spec.name} (${cols.join(", ")}) VALUES ${placeholders} ON CONFLICT DO NOTHING`,
      params,
    );
    migrated += chunk.length;
    process.stdout.write(`\r  ${spec.name}: ${Math.min(migrated, total)}/${total}`);
  }
  process.stdout.write("\n");
  return migrated;
}

async function main() {
  if (!fs.existsSync(sqlitePath)) {
    console.error(`找不到 SQLite 源库: ${sqlitePath}`);
    process.exit(1);
  }
  console.log(`源库: ${sqlitePath}`);
  console.log(`目标: ${process.env.DATABASE_URL ?? "(默认 localhost couplechat)"}`);

  const sqlite = new DatabaseSync(sqlitePath, { readOnly: true });
  await initDatabase(); // 建好 PG 表结构

  let total = 0;
  for (const spec of TABLES) {
    total += await migrateTable(sqlite, spec);
  }

  sqlite.close();
  await closeDatabase();
  console.log(`迁移完成，共 ${total} 行。`);
}

main().catch((error) => {
  console.error("迁移失败:", error);
  process.exit(1);
});
