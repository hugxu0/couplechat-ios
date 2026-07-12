import { allOn, databasePool, runOn } from "./client";

export interface DatabaseTransaction {
  run(sql: string, params?: any[]): Promise<number>;
  all<T extends object>(sql: string, params?: any[]): Promise<T[]>;
  get<T extends object>(sql: string, params?: any[]): Promise<T | undefined>;
}

export async function transaction<T>(work: (db: DatabaseTransaction) => Promise<T>): Promise<T> {
  const client = await databasePool().connect();
  const db: DatabaseTransaction = {
    run: (sql, params = []) => runOn(client, sql, params),
    all: <R extends object>(sql: string, params: any[] = []) => allOn<R>(client, sql, params),
    async get<R extends object>(sql: string, params: any[] = []): Promise<R | undefined> {
      const rows = await allOn<R>(client, sql, params);
      return rows[0];
    },
  };
  try {
    await client.query("BEGIN");
    const value = await work(db);
    await client.query("COMMIT");
    return value;
  } catch (error) {
    await client.query("ROLLBACK").catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}
