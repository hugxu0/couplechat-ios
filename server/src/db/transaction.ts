import type { Pool } from "pg";
import { allOn, databasePool, runOn } from "./client";

const databaseTransactionBrand: unique symbol = Symbol("databaseTransaction");
const activeTransactions = new WeakSet<object>();

export interface DatabaseTransaction {
  readonly [databaseTransactionBrand]: true;
  run(sql: string, params?: any[]): Promise<number>;
  all<T extends object>(sql: string, params?: any[]): Promise<T[]>;
  get<T extends object>(sql: string, params?: any[]): Promise<T | undefined>;
}

export function assertActiveDatabaseTransaction(db: DatabaseTransaction): void {
  if (!activeTransactions.has(db)) throw new Error("active_database_transaction_required");
}

/** @internal Exposed for isolated PostgreSQL concurrency tests. */
export async function transactionOnPool<T>(
  pool: Pool,
  work: (db: DatabaseTransaction) => Promise<T>,
): Promise<T> {
  const client = await pool.connect();
  const db: DatabaseTransaction = {
    [databaseTransactionBrand]: true,
    run: (sql, params = []) => runOn(client, sql, params),
    all: <R extends object>(sql: string, params: any[] = []) => allOn<R>(client, sql, params),
    async get<R extends object>(sql: string, params: any[] = []): Promise<R | undefined> {
      const rows = await allOn<R>(client, sql, params);
      return rows[0];
    },
  };
  try {
    await client.query("BEGIN");
    activeTransactions.add(db);
    const value = await work(db);
    await client.query("COMMIT");
    return value;
  } catch (error) {
    await client.query("ROLLBACK").catch(() => undefined);
    throw error;
  } finally {
    activeTransactions.delete(db);
    client.release();
  }
}

export async function transaction<T>(work: (db: DatabaseTransaction) => Promise<T>): Promise<T> {
  return transactionOnPool(databasePool(), work);
}
