import { Pool } from "pg";
import { config } from "../src/config";
import { migrate, schemaMigrations } from "../src/db/migrate";

const pool = new Pool({ connectionString: config.databaseUrl, max: 1 });
try {
  await migrate(pool);
  console.info(`[db] 受控 migrator 完成，schema=v${schemaMigrations.at(-1)?.version ?? 0}`);
} finally {
  await pool.end();
}
