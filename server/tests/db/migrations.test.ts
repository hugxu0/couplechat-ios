import assert from "node:assert/strict";
import crypto from "node:crypto";
import test from "node:test";
import { schemaMigrations } from "../../src/db/migrate";

const publishedMigrations = [
  [1, "initial_schema", "f807e14075a84885"],
  [2, "bind_uploads_to_messages", "619165dbd02b5fd8"],
  [3, "classify_upload_purpose", "f875441ef362673d"],
  [4, "preserve_recalled_text", "4aebe31dfc2b4608"],
  [5, "message_attachments", "9aee776bc01744a2"],
  [6, "memory_v2", "e91def913345f801"],
  [7, "canonical_memory_names", "96eecd2502add972"],
  [8, "ensure_ai_runtime_state", "e3f67f6b71206be8"],
  [9, "memory_import_staging", "eba936eafd201843"],
  [10, "memory_cursor_tie_breaker", "bc5ca10f772da38b"],
] as const;

test("published migration SQL remains byte-for-byte append-only", () => {
  assert.equal(schemaMigrations.length, publishedMigrations.length);
  for (const [index, migration] of schemaMigrations.entries()) {
    const [version, name, expectedHash] = publishedMigrations[index];
    const hash = crypto.createHash("sha256").update(migration.sql).digest("hex").slice(0, 16);
    assert.deepEqual([migration.version, migration.name, hash], [version, name, expectedHash]);
  }
});
