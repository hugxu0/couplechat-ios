// 用本地旧生产快照 + 临时 PostgreSQL 验证完整旧→新转换，不接触线上数据。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import EmbeddedPostgres from "embedded-postgres";

const PORT = 5545;
const pgDir = fs.mkdtempSync(path.join(os.tmpdir(), "couplechat-legacy-pg-"));

async function main(): Promise<void> {
  const legacyDb = path.resolve("../data/chat.db");
  const legacyDocs = path.resolve("../data/ai_docs");
  const legacyUploads = path.resolve("../data/uploads");
  for (const required of [legacyDb, legacyDocs, legacyUploads]) {
    if (!fs.existsSync(required)) throw new Error(`缺少本地旧数据快照: ${required}`);
  }

  const pg = new EmbeddedPostgres({
    databaseDir: pgDir,
    user: "couplechat",
    password: "couplechat",
    port: PORT,
    persistent: false,
  });
  await pg.initialise();
  await pg.start();
  await pg.createDatabase("couplechat");
  process.env.DATABASE_URL = `postgres://couplechat:couplechat@localhost:${PORT}/couplechat`;
  process.env.IMPORT_LEGACY_REPLACE = "YES";
  process.env.LEGACY_SQLITE_PATH = legacyDb;
  process.env.LEGACY_AI_DOCS_PATH = legacyDocs;
  process.env.LEGACY_UPLOADS_PATH = legacyUploads;

  try {
    const db = await import("../src/db");
    await db.initDatabase();
    const now = Date.now();
    for (const [username, name] of [["xu", "小旭"], ["si", "小偲"]]) {
      await db.run(
        "INSERT INTO accounts (username,display_name,password_hash,avatar,bark_key,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
        [username, name, "preserve-me", "", "preserve-bark", now, now],
      );
    }
    await db.run(
      "INSERT INTO messages (id,channel,sender,sender_name,kind,type,text,ts) VALUES (?,?,?,?,?,?,?,?)",
      ["test_should_disappear", "couple", "xu", "小旭", "user", "text", "测试数据", now],
    );
    await db.closeDatabase();

    const { importLegacyProduction } = await import("./import-legacy-production");
    await importLegacyProduction();

    await db.initDatabase();
    const counts = Object.fromEntries(await Promise.all(
      ["messages", "shared_items", "personal_items", "uploads", "ai_facts", "ai_episodes", "ai_docs"].map(async (table) => {
        const row = await db.get<{ n: number }>(`SELECT COUNT(*) AS n FROM ${table}`);
        return [table, row?.n ?? 0];
      }),
    ));
    const source = new (await import("node:sqlite")).DatabaseSync(legacyDb, { readOnly: true });
    const sourceMessages = Number((source.prepare("SELECT COUNT(*) AS n FROM messages").get() as { n: number }).n);
    const sourceFacts = Number((source.prepare("SELECT COUNT(*) AS n FROM memory_facts").get() as { n: number }).n);
    const sourceEpisodes = Number((source.prepare("SELECT COUNT(*) AS n FROM knowledge_cards").get() as { n: number }).n);
    const sourceShared = Number((source.prepare("SELECT COUNT(*) AS n FROM shared").get() as { n: number }).n);
    source.close();
    const unmapped = await db.get<{ n: number }>(
      "SELECT COUNT(*) AS n FROM messages WHERE sender IN ('alice','bob') OR channel IN ('ai:alice','ai:bob')",
    );
    const testRow = await db.get<{ id: string }>("SELECT id FROM messages WHERE id = ?", ["test_should_disappear"]);
    const account = await db.get<{ password_hash: string; bark_key: string }>("SELECT password_hash,bark_key FROM accounts WHERE username='xu'");
    const shortTerm = await db.get<{ text: string }>("SELECT text FROM ai_docs WHERE key='short-term'");
    const legacyCache = await db.get<{ n: number }>("SELECT COUNT(*) AS n FROM ai_docs WHERE key LIKE 'legacy-cache:%'");
    const legacyUpload = await db.get<{ url: string }>("SELECT url FROM uploads WHERE url LIKE '%/uploads/%' ORDER BY created_at LIMIT 1");

    const checks: Array<[string, boolean]> = [
      ["消息全量", counts.messages === sourceMessages],
      ["测试消息被替换", !testRow],
      ["用户名和私聊频道完成映射", (unmapped?.n ?? 1) === 0],
      ["账号密码和 Bark 保留", account?.password_hash === "preserve-me" && account.bark_key === "preserve-bark"],
      ["共享状态全量", counts.shared_items === sourceShared],
      ["提醒/备忘已转换", counts.personal_items > 0],
      ["媒体索引已生成", counts.uploads === fs.readdirSync(legacyUploads).filter((name) => fs.statSync(path.join(legacyUploads, name)).isFile()).length],
      ["长期事实全量", counts.ai_facts === sourceFacts],
      ["事件卡全量", counts.ai_episodes === sourceEpisodes],
      ["短期记忆存在", Boolean(shortTerm?.text)],
      ["旧 AI 缓存归档", (legacyCache?.n ?? 0) > 0],
      ["旧媒体 URL 可索引", Boolean(legacyUpload?.url)],
    ];
    for (const [label, ok] of checks) console.log(`  ${ok ? "✓" : "✗"} ${label}`);
    if (checks.some(([, ok]) => !ok)) throw new Error("旧数据转换冒烟测试失败");
    console.log("旧数据转换冒烟测试全部通过 ✓", counts);
    await db.closeDatabase();
  } finally {
    await pg.stop().catch(() => undefined);
    fs.rmSync(pgDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
