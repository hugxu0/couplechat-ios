import { Pool, type PoolClient, types } from "pg";
import { config } from "../config";
import { migrate, schemaMigrations } from "./migrate";

types.setTypeParser(20, (value) => Number(value));

let pool: Pool | null = null;

export type Queryable = Pick<Pool | PoolClient, "query">;

export function databasePool(): Pool {
  if (!pool) throw new Error("Database is not initialized");
  return pool;
}

function toPg(sql: string): string {
  let index = 0;
  return sql.replace(/\?/g, () => `$${++index}`);
}

function normalizeParams(params: any[]): any[] {
  return params.map((param) => {
    if (param === undefined) return null;
    if (param instanceof Uint8Array && !Buffer.isBuffer(param)) {
      return Buffer.from(param.buffer, param.byteOffset, param.byteLength);
    }
    return param;
  });
}

export async function runOn(queryable: Queryable, sql: string, params: any[] = []): Promise<number> {
  const result = await queryable.query(toPg(sql), normalizeParams(params));
  return result.rowCount ?? 0;
}

export async function allOn<T extends object>(
  queryable: Queryable,
  sql: string,
  params: any[] = [],
): Promise<T[]> {
  const result = await queryable.query(toPg(sql), normalizeParams(params));
  return result.rows as T[];
}

export async function initDatabase(throughVersion?: number): Promise<void> {
  const nextPool = new Pool({ connectionString: config.databaseUrl, max: 10 });
  // pg.Pool emits idle-client failures as EventEmitter errors. Without a
  // listener, a PostgreSQL restart can terminate the entire Node process.
  nextPool.on("error", (error) => {
    if (pool === nextPool) console.error("[db] idle connection error", error);
  });
  pool = nextPool;
  await nextPool.query("SELECT 1");
  if (throughVersion !== undefined || config.runMigrations) {
    await migrate(nextPool, throughVersion);
    return;
  }
  const expected = schemaMigrations.at(-1)?.version ?? 0;
  const result = await nextPool.query<{ version: number | null }>(
    "SELECT MAX(version) AS version FROM schema_migrations",
  ).catch(() => ({ rows: [{ version: null }] }));
  if (Number(result.rows[0]?.version ?? 0) !== expected) {
    throw new Error(`[db] schema 未就绪：期望 v${expected}。请先运行 npm run migrate`);
  }
}

export async function closeDatabase(): Promise<void> {
  const closingPool = pool;
  pool = null;
  await closingPool?.end();
}

export async function pingDatabase(): Promise<void> {
  await databasePool().query("SELECT 1");
}

export async function run(sql: string, params: any[] = []): Promise<number> {
  return runOn(databasePool(), sql, params);
}

export async function all<T extends object>(sql: string, params: any[] = []): Promise<T[]> {
  return allOn<T>(databasePool(), sql, params);
}

export async function get<T extends object>(sql: string, params: any[] = []): Promise<T | undefined> {
  const rows = await all<T>(sql, params);
  return rows[0];
}
