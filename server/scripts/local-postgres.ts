import fs from "node:fs";
import path from "node:path";
import EmbeddedPostgres from "embedded-postgres";

const databaseDir = path.resolve(process.env.LOCAL_POSTGRES_DIR ?? ".data/local-postgres");
const port = Number(process.env.LOCAL_POSTGRES_PORT ?? 55432);
const user = process.env.LOCAL_POSTGRES_USER ?? "couplechat";
const password = process.env.LOCAL_POSTGRES_PASSWORD ?? "couplechat";
const database = process.env.LOCAL_POSTGRES_DATABASE ?? "couplechat";

async function main() {
  const pg = new EmbeddedPostgres({
    databaseDir,
    port,
    user,
    password,
    persistent: true,
    onLog(message) {
      const line = message.trim();
      if (line) console.log(`[local-postgres] ${line}`);
    },
  });

  if (!fs.existsSync(path.join(databaseDir, "PG_VERSION"))) {
    console.log(`[local-postgres] 初始化数据目录 ${databaseDir}`);
    await pg.initialise();
  }

  await pg.start();
  const client = pg.getPgClient("postgres", "127.0.0.1");
  await client.connect();
  const exists = await client.query("SELECT 1 FROM pg_database WHERE datname = $1", [database]);
  await client.end();
  if (exists.rowCount === 0) await pg.createDatabase(database);

  console.log(`[local-postgres] 已启动：postgres://${user}:***@127.0.0.1:${port}/${database}`);
  await new Promise<void>(() => {});
}

main().catch((error) => {
  console.error("[local-postgres] 启动失败", error);
  process.exit(1);
});
