import { Pool } from "pg";
import { config } from "./config";
import { migrate, schemaMigrations } from "./db/migrate";

async function main(): Promise<void> {
  const pool = new Pool({ connectionString: config.databaseUrl, max: 1 });
  try {
    await migrate(pool);
    console.info(`[db] 受控 migrator 完成，schema=v${schemaMigrations.at(-1)?.version ?? 0}`);
  } finally {
    await pool.end();
  }
}

main().catch((error) => {
  console.error(`[db] migrator 失败：${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
