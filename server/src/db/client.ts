import { Pool, type PoolClient, types } from "pg";
import { config } from "../config";
import { migrate } from "./migrate";

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

export async function initDatabase(): Promise<void> {
  pool = new Pool({ connectionString: config.databaseUrl, max: 10 });
  await pool.query("SELECT 1");
  await migrate(pool);
}

export async function closeDatabase(): Promise<void> {
  await pool?.end();
  pool = null;
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
