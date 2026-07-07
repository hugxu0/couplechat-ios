// PostgreSQL 冒烟测试：起一个内嵌 PG → 建表 → 从 .data/couplechat.sqlite 全量迁移 →
// 跑一遍代表性读写路径，验证 SQL 方言/占位符转换/BYTEA/BIGINT 解析都正确。
// 用法（server/ 下）：npx tsx scripts/smoke-postgres.ts

import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import EmbeddedPostgres from "embedded-postgres";

const PORT = 5544;
const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "couplechat-pg-"));

async function main() {
  const pg = new EmbeddedPostgres({
    databaseDir: dataDir,
    user: "couplechat",
    password: "couplechat",
    port: PORT,
    persistent: false,
  });

  console.log("[1/5] 初始化内嵌 PostgreSQL…");
  await pg.initialise();
  await pg.start();
  await pg.createDatabase("couplechat");

  process.env.DATABASE_URL = `postgres://couplechat:couplechat@localhost:${PORT}/couplechat`;

  try {
    // 动态 import：确保 config 读到上面设置的 DATABASE_URL
    const db = await import("../src/db");
    console.log("[2/5] 建表…");
    await db.initDatabase();

    console.log("[3/5] 迁移 SQLite 数据…");
    const { DatabaseSync } = await import("node:sqlite");
    const sqlite = new DatabaseSync(path.resolve(".data/couplechat.sqlite"), { readOnly: true });

    const tables: Array<{ name: string; columns: string[] }> = [
      { name: "accounts", columns: ["username", "display_name", "password_hash", "avatar", "bark_key", "created_at", "updated_at"] },
      { name: "messages", columns: ["id", "channel", "sender", "sender_name", "kind", "type", "text", "url", "reply_json", "meta_json", "ts", "client_id"] },
      { name: "read_receipts", columns: ["channel", "username", "ts", "updated_at"] },
      { name: "shared_items", columns: ["key", "value_json", "updated_by", "updated_at"] },
      { name: "personal_items", columns: ["id", "owner", "kind", "scope", "title", "body_markdown", "due_at", "is_done", "created_at", "updated_at"] },
      { name: "uploads", columns: ["id", "owner", "path", "url", "mime_type", "size", "created_at"] },
      { name: "ai_facts", columns: ["id", "subject", "category", "text", "importance", "status", "embedding", "created_at", "updated_at", "last_seen_at"] },
      { name: "ai_episodes", columns: ["id", "channel", "date", "title", "summary", "key_points_json", "mood", "conclusion", "keywords", "embedding", "created_at"] },
      { name: "ai_docs", columns: ["key", "text", "updated_at"] },
    ];
    for (const t of tables) {
      const rows = sqlite.prepare(`SELECT ${t.columns.map((c) => `"${c}"`).join(",")} FROM "${t.name}"`).all() as Record<string, unknown>[];
      for (let i = 0; i < rows.length; i += 500) {
        const chunk = rows.slice(i, i + 500);
        const values = chunk.map(() => `(${t.columns.map(() => "?").join(",")})`).join(",");
        await db.run(
          `INSERT INTO ${t.name} (${t.columns.join(",")}) VALUES ${values} ON CONFLICT DO NOTHING`,
          chunk.flatMap((r) => t.columns.map((c) => r[c] ?? null)),
        );
      }
      console.log(`  ${t.name}: ${rows.length} 行`);
    }
    sqlite.close();

    console.log("[4/5] 服务层冒烟…");
    const assertOk = (label: string, cond: boolean) => {
      console.log(`  ${cond ? "✓" : "✗"} ${label}`);
      if (!cond) process.exitCode = 1;
    };

    // 账号
    const { listPublicAccounts, authenticate } = await import("../src/auth/accounts");
    const accounts = await listPublicAccounts();
    assertOk(`listPublicAccounts → ${accounts.length} 个账号`, accounts.length === 2);

    // 消息：分页 / since / around / 搜索 / LIKE
    const { fetchMessages, searchMessages, createMessage, upsertReadReceipt, getReadReceipts } = await import("../src/chat/messageService");
    const user = { username: accounts[0].username, name: accounts[0].name };
    const latest = await fetchMessages(user, { channel: "couple", limit: 50 });
    assertOk(`fetchMessages latest → ${latest.length} 条`, latest.length === 50);
    assertOk("ts 是 number", typeof latest[0].ts === "number" && latest[0].ts > 1e12);
    const before = await fetchMessages(user, { channel: "couple", before: latest[0].ts, limit: 20 });
    assertOk(`fetchMessages before → ${before.length} 条且时序正确`, before.length === 20 && before[19].ts <= latest[0].ts);
    const found = await searchMessages(user, "couple", "喵", 10);
    assertOk(`searchMessages "喵" → ${found.length} 条`, found.length > 0);

    // 写入一条新消息（含 reply/meta JSON + clientId 幂等）
    const created = await createMessage(user, { channel: "couple", type: "text", text: "PG 冒烟测试", clientId: "smoke-1" });
    const dup = await createMessage(user, { channel: "couple", type: "text", text: "PG 冒烟测试重复", clientId: "smoke-1" });
    assertOk("clientId 幂等（重发返回同一条）", created.id === dup.id);

    // 已读回执 upsert
    await upsertReadReceipt(user, "couple", created.ts);
    await upsertReadReceipt(user, "couple", created.ts + 5);
    const receipts = await getReadReceipts(user, "couple");
    assertOk("read_receipts ON CONFLICT 更新", receipts[user.username] === created.ts + 5);

    // shared kv
    const { setSharedItem, getSharedState } = await import("../src/shared/sharedService");
    await setSharedItem(user, "smoke", { hello: "pg" });
    await setSharedItem(user, "smoke", { hello: "pg2" });
    const shared = await getSharedState();
    assertOk("shared_items upsert", (shared.smoke?.value as { hello?: string })?.hello === "pg2");

    // personal items CRUD
    const items = await import("../src/personalItems/itemService");
    const item = await items.createPersonalItem(user, { kind: "reminder", title: "冒烟提醒", dueAt: Date.now() + 60000 });
    assertOk("createPersonalItem", Boolean(item?.id));
    const patched = await items.updatePersonalItem(user, item!.id, { isDone: true });
    assertOk("updatePersonalItem isDone", patched?.isDone === true);
    assertOk("deletePersonalItem", await items.deletePersonalItem(user, item!.id));

    // AI 记忆：embedding BYTEA 读回 + 向量解包
    const { listFacts, getDoc, setDoc, listEpisodes } = await import("../src/ai/memoryStore");
    const facts = await listFacts({ limit: 2000 });
    const withVector = facts.filter((f) => f.vector && f.vector.length > 0);
    assertOk(`ai_facts → ${facts.length} 条（${withVector.length} 条带向量）`, facts.length === 95 && withVector.length > 0);
    const episodes = await listEpisodes("couple");
    assertOk(`ai_episodes(couple) → ${episodes.length} 张卡`, episodes.length > 0);
    await setDoc("smoke-doc", "hello");
    await setDoc("smoke-doc", "hello2");
    assertOk("ai_docs upsert", (await getDoc("smoke-doc")) === "hello2");

    // 统计（to_char 方言改写）
    const buckets = await db.all<{ sender: string; bucket: string; c: number }>(
      `SELECT sender, to_char(to_timestamp(ts / 1000.0) AT TIME ZONE 'UTC' + interval '8 hours', 'YYYY-MM-DD') AS bucket, COUNT(*) AS c
       FROM messages WHERE channel = 'couple' AND kind = 'user' AND sender != 'ai' AND ts >= ?
       GROUP BY sender, bucket ORDER BY bucket DESC LIMIT 5`,
      [Date.now() - 30 * 24 * 3600 * 1000],
    );
    assertOk(`统计聚合 → ${buckets.length} 桶，COUNT 是 number`, buckets.length > 0 && typeof buckets[0].c === "number");

    console.log("[5/5] 清理…");
    await db.closeDatabase();
  } finally {
    await pg.stop();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
  console.log(process.exitCode ? "冒烟测试有失败项 ✗" : "冒烟测试全部通过 ✓");
}

main().catch((error) => {
  console.error("冒烟测试失败:", error);
  process.exit(1);
});
