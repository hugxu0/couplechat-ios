import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { Pool } from "pg";
import { clientChannelSchema, readReceiptSchema } from "../../src/contracts/realtime";
import { toClientChannel, toStoredChannel } from "../../src/types";
import { withTestDatabase } from "../support/postgresHarness";

interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T): void;
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitUntil(
  predicate: () => Promise<boolean>,
  message: string,
  timeoutMilliseconds = 5_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await delay(10);
  }
  throw new Error(message);
}

function typescriptFiles(directory: string): string[] {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const resolved = path.join(directory, entry.name);
    return entry.isDirectory() ? typescriptFiles(resolved) : entry.name.endsWith(".ts") ? [resolved] : [];
  });
}

test("sync contracts normalize iOS timestamps and isolate AI channels", () => {
  const receipt = readReceiptSchema.parse({ channel: "couple", ts: 1783653931714.444 });
  assert.equal(receipt.ts, 1783653931714);
  assert.equal(clientChannelSchema.safeParse("unknown").success, false);
  assert.equal(toStoredChannel("ai", "xu"), "ai:xu");
  assert.equal(toClientChannel("ai:xu"), "ai");
  assert.equal(toStoredChannel("couple", "xu"), "couple");
});

test("runtime sync event writes cannot bypass appendSyncEvent", () => {
  const sourceRoot = path.resolve(__dirname, "../../src");
  const directWriters = typescriptFiles(sourceRoot)
    .filter((filename) => path.relative(sourceRoot, filename) !== path.join("db", "migrate.ts"))
    .filter((filename) => {
      const source = fs.readFileSync(filename, "utf8");
      return /nextval\(['"]sync_event_seq['"]\)|INSERT\s+INTO\s+sync_events/i.test(source);
    })
    .map((filename) => path.relative(sourceRoot, filename).replaceAll("\\", "/"));
  assert.deepEqual(directWriters, ["sync/events.ts"]);
});

test("Sync V2 sequence allocation is serialized through commit", { timeout: 60_000 }, async (t) => {
  await withTestDatabase(async () => {
    const database = await import("../../src/db");
    const { appendSyncEvent } = await import("../../src/sync/events");
    const { transactionOnPool } = await import("../../src/db/transaction");
    const now = Date.now();
    const accountId = "acc_sync_ordering";
    await database.run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES (?, 'sync-ordering', 'Sync Ordering', 'unused', '', 'active', 0, ?, ?)`,
      [accountId, now, now],
    );

    const input = (entityType: string, entityId: string) => ({
      accountId,
      entityType,
      entityId,
      operation: "upsert" as const,
      payload: { id: entityId },
    });

    await t.test("rejects a transaction handle after its transaction has ended", async () => {
      let expiredTransaction: Parameters<typeof appendSyncEvent>[0] | undefined;
      await database.transaction(async (db) => { expiredTransaction = db; });
      assert.ok(expiredTransaction);
      await assert.rejects(
        () => appendSyncEvent(expiredTransaction!, input("transaction_guard", "expired")),
        /active_database_transaction_required/,
      );
    });

    await t.test("two connections cannot commit a larger sequence first", async () => {
      const firstAllocated = deferred<{ pid: number; seq: number }>();
      const releaseFirst = deferred<void>();
      const secondStarted = deferred<number>();

      const first = database.transaction(async (db) => {
        const session = await db.get<{ pid: number }>("SELECT pg_backend_pid() AS pid");
        assert.ok(session);
        const seq = await appendSyncEvent(db, input("reverse_commit", "first"));
        firstAllocated.resolve({ pid: session.pid, seq });
        await releaseFirst.promise;
        return seq;
      });
      const firstState = await firstAllocated.promise;

      const second = database.transaction(async (db) => {
        const session = await db.get<{ pid: number }>("SELECT pg_backend_pid() AS pid");
        assert.ok(session);
        secondStarted.resolve(session.pid);
        return appendSyncEvent(db, input("reverse_commit", "second"));
      });
      const secondPid = await secondStarted.promise;
      assert.notEqual(secondPid, firstState.pid);

      try {
        await waitUntil(async () => {
          const waiting = await database.get<{ wait_event_type: string | null; wait_event: string | null }>(
            "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = ?",
            [secondPid],
          );
          return waiting?.wait_event_type === "Lock" && waiting.wait_event === "advisory";
        }, "second sync writer did not wait on the commit-order advisory lock");
        const visible = await database.all<{ entity_id: string }>(
          "SELECT entity_id FROM sync_events WHERE entity_type = 'reverse_commit'",
        );
        assert.deepEqual(visible, []);
      } finally {
        releaseFirst.resolve();
      }

      const [firstSeq, secondSeq] = await Promise.all([first, second]);
      assert.equal(firstSeq, firstState.seq);
      assert.ok(firstSeq < secondSeq);
      const committed = await database.all<{ seq: number; entity_id: string }>(
        `SELECT seq, entity_id FROM sync_events
          WHERE entity_type = 'reverse_commit' ORDER BY seq`,
      );
      assert.deepEqual(committed, [
        { seq: firstSeq, entity_id: "first" },
        { seq: secondSeq, entity_id: "second" },
      ]);
    });

    await t.test("rollback leaves a safe sequence gap", async () => {
      let rolledBackSeq = 0;
      await assert.rejects(
        () => database.transaction(async (db) => {
          rolledBackSeq = await appendSyncEvent(db, input("rollback_gap", "rolled-back"));
          throw new Error("intentional_sync_rollback");
        }),
        /intentional_sync_rollback/,
      );
      const committedSeq = await database.transaction((db) =>
        appendSyncEvent(db, input("rollback_gap", "committed")));
      assert.equal(committedSeq, rolledBackSeq + 1);
      const rows = await database.all<{ seq: number; entity_id: string }>(
        "SELECT seq, entity_id FROM sync_events WHERE entity_type = 'rollback_gap' ORDER BY seq",
      );
      assert.deepEqual(rows, [{ seq: committedSeq, entity_id: "committed" }]);
    });

    await t.test("one transaction can append multiple consecutive events atomically", async () => {
      const sequences = await database.transaction(async (db) => [
        await appendSyncEvent(db, input("multi_event", "one")),
        await appendSyncEvent(db, input("multi_event", "two")),
        await appendSyncEvent(db, input("multi_event", "three")),
      ]);
      assert.deepEqual(sequences, [sequences[0], sequences[0] + 1, sequences[0] + 2]);
      const rows = await database.all<{ seq: number; entity_id: string }>(
        "SELECT seq, entity_id FROM sync_events WHERE entity_type = 'multi_event' ORDER BY seq",
      );
      assert.deepEqual(rows, [
        { seq: sequences[0], entity_id: "one" },
        { seq: sequences[1], entity_id: "two" },
        { seq: sequences[2], entity_id: "three" },
      ]);
    });

    await t.test("polling does not skip late commits from twenty concurrent transactions", async () => {
      const startCursorRow = await database.get<{ seq: number }>(
        "SELECT COALESCE(MAX(seq), 0) AS seq FROM sync_events",
      );
      const startCursor = startCursorRow?.seq ?? 0;
      const concurrentPool = new Pool({ connectionString: process.env.DATABASE_URL, max: 21 });
      const pollClient = await concurrentPool.connect();
      const releaseWriters = deferred<void>();
      const allWritersReady = deferred<void>();
      const writerPids = new Set<number>();
      let writersDone = false;
      let cursor = startCursor;
      const observed: Array<{ seq: number; entity_id: string }> = [];

      const writers = Array.from({ length: 20 }, (_, index) =>
        transactionOnPool(concurrentPool, async (db) => {
          const session = await db.get<{ pid: number }>("SELECT pg_backend_pid() AS pid");
          assert.ok(session);
          writerPids.add(session.pid);
          if (writerPids.size === 20) allWritersReady.resolve();
          await releaseWriters.promise;
          const seq = await appendSyncEvent(db, input("concurrent_poll", `writer-${index}`));
          // Without the advisory lock these delays make later allocations commit first.
          await delay((20 - index) % 5 + 1);
          return seq;
        }));

      try {
        await allWritersReady.promise;
        assert.equal(writerPids.size, 20);
        const poller = (async () => {
          let emptyPollsAfterCompletion = 0;
          while (!writersDone || emptyPollsAfterCompletion < 2) {
            const result = await pollClient.query<{ seq: number; entity_id: string }>(
              `SELECT seq, entity_id FROM sync_events
                WHERE seq > $1 AND account_id = $2
                ORDER BY seq ASC LIMIT 4`,
              [cursor, accountId],
            );
            if (result.rows.length > 0) {
              for (const row of result.rows) {
                assert.ok(row.seq > cursor);
                observed.push(row);
              }
              cursor = result.rows.at(-1)!.seq;
              emptyPollsAfterCompletion = 0;
            } else {
              if (writersDone) emptyPollsAfterCompletion += 1;
              await delay(1);
            }
          }
        })();

        releaseWriters.resolve();
        const sequences = await Promise.all(writers);
        writersDone = true;
        await poller;
        assert.equal(new Set(sequences).size, 20);

        const committed = await database.all<{ seq: number; entity_id: string }>(
          `SELECT seq, entity_id FROM sync_events
            WHERE entity_type = 'concurrent_poll' ORDER BY seq`,
        );
        assert.equal(committed.length, 20);
        assert.deepEqual(observed, committed);
        assert.equal(cursor, committed.at(-1)?.seq);
      } finally {
        releaseWriters.resolve();
        await Promise.allSettled(writers);
        pollClient.release();
        await concurrentPool.end();
      }
    });
  });
});
