// 一次性迁移：.data/couplechat.sqlite → PostgreSQL。
// 幂等：全部 INSERT ... ON CONFLICT DO NOTHING，重复跑不会产生脏数据。
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
  // BLOB 列名（需要保持 Buffer 原样传给 pg）
  blobColumns?: string[];
}

const TABLES: TableSpec[] = [
  { name: "accounts", columns: ["username", "display_name", "password_hash", "avatar", "bark_key", "created_at", "updated_at"] },
  { name: "messages", columns: ["id", "channel", "sender", "sender_name", "kind", "type", "text", "url", "reply_json", "meta_json", "ts", "client_id"] },
  { name: "read_receipts", columns: ["channel", "username", "ts", "updated_at"] },
  { name: "shared_items", columns: ["key", "value_json", "updated_by", "updated_at"] },
  { name: "personal_items", columns: ["id", "owner", "kind", "scope", "title", "body_markdown", "due_at", "is_done", "created_at", "updated_at"] },
  { name: "uploads", columns: ["id", "owner", "path", "url", "mime_type", "size", "created_at"] },
  { name: "ai_facts", columns: ["id", "subject", "category", "text", "importance", "status", "embedding", "created_at", "updated_at", "last_seen_at"], blobColumns: ["embedding"] },
  { name: "ai_episodes", columns: ["id", "channel", "date", "title", "summary", "key_points_json", "mood", "conclusion", "keywords", "embedding", "created_at"], blobColumns: ["embedding"] },
  { name: "ai_docs", columns: ["key", "text", "updated_at"] },
];

const BATCH = 500;

async function migrateTable(sqlite: DatabaseSync, spec: TableSpec): Promise<number> {
  let rows: Record<string, unknown>[];
  try {
    rows = sqlite.prepare(`SELECT ${spec.columns.map((c) => `"${c}"`).join(", ")} FROM "${spec.name}"`).all() as Record<string, unknown>[];
  } catch (error) {
    console.warn(`  跳过 ${spec.name}（源表不存在或读取失败）: ${error instanceof Error ? error.message : error}`);
    return 0;
  }
  if (!rows.length) {
    console.log(`  ${spec.name}: 0 行`);
    return 0;
  }

  const cols = spec.columns;
  for (let offset = 0; offset < rows.length; offset += BATCH) {
    const chunk = rows.slice(offset, offset + BATCH);
    // 多行 VALUES 拼一条 INSERT，占位符由 db 层统一转 $n
    const placeholders = chunk
      .map((_, r) => `(${cols.map(() => "?").join(", ")})`)
      .join(", ");
    const params = chunk.flatMap((row) => cols.map((c) => row[c] ?? null));
    await run(
      `INSERT INTO ${spec.name} (${cols.join(", ")}) VALUES ${placeholders} ON CONFLICT DO NOTHING`,
      params,
    );
    process.stdout.write(`\r  ${spec.name}: ${Math.min(offset + BATCH, rows.length)}/${rows.length}`);
  }
  process.stdout.write("\n");
  return rows.length;
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
