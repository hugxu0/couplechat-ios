import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import EmbeddedPostgres from "embedded-postgres";
import { installSafeTestEnvironment } from "./testEnv";

async function availablePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

export async function withTestDatabase<T>(
  work: () => Promise<T>,
  options: { migrateThrough?: number; environment?: Record<string, string> } = {},
): Promise<T> {
  installSafeTestEnvironment();
  for (const [key, value] of Object.entries(options.environment ?? {})) {
    process.env[key] = value;
  }
  const port = await availablePort();
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "couplechat-test-pg-"));
  const postgres = new EmbeddedPostgres({
    databaseDir: dataDir,
    user: "couplechat_test",
    password: "couplechat_test",
    port,
    persistent: false,
  });
  await postgres.initialise();
  await postgres.start();
  await postgres.createDatabase("couplechat_test");
  process.env.DATABASE_URL = `postgres://couplechat_test:couplechat_test@127.0.0.1:${port}/couplechat_test`;
  process.env.DATA_DIR = dataDir;
  process.env.UPLOAD_DIR = dataDir;

  const db = await import("../../src/db");
  try {
    await db.initDatabase(options.migrateThrough);
    return await work();
  } finally {
    await db.closeDatabase().catch(() => undefined);
    await postgres.stop().catch(() => undefined);
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
}
