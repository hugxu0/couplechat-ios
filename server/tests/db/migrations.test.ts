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
  assert.ok(schemaMigrations.length >= publishedMigrations.length);
  for (const [index, migration] of schemaMigrations.slice(0, publishedMigrations.length).entries()) {
    const [version, name, expectedHash] = publishedMigrations[index];
    const hash = crypto.createHash("sha256").update(migration.sql).digest("hex").slice(0, 16);
    assert.deepEqual([migration.version, migration.name, hash], [version, name, expectedHash]);
  }
});

test("candidate migrations remain ordered after the published boundary", () => {
  const candidates = schemaMigrations.slice(publishedMigrations.length);
  assert.deepEqual(candidates.map((item) => [item.version, item.name]), [
    [11, "hard_delete_recalled_messages"],
    [12, "durable_reminder_bark_delivery"],
    [13, "identity_v2_expand"],
    [14, "devices_sessions_push"],
    [15, "reminder_delivery_per_endpoint"],
    [16, "conversations_and_ownership"],
    [17, "sync_v2_core"],
    [18, "tenant_memory_and_settings"],
    [19, "voice_transcription"],
    [20, "shared_albums"],
    [21, "shared_calendar"],
    [22, "shared_pet"],
    [23, "pet_care_state"],
    [24, "remove_public_registration_invites"],
  ]);
});
