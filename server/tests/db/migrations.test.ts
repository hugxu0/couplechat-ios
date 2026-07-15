import assert from "node:assert/strict";
import crypto from "node:crypto";
import test from "node:test";
import { schemaMigrations } from "../../src/db/migrate";
import { withTestDatabase } from "../support/postgresHarness";

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
    [25, "album_timeline_posts"],
    [26, "memory_derivation_dependencies"],
    [27, "retire_memory_message_evidence"],
    [28, "enforce_single_active_rolling_memory"],
    [29, "daily_recommendations"],
    [30, "daju_memory_perspective"],
  ]);
});

test("v28 keeps only the newest active rolling card and enforces the invariant", async () => {
  await withTestDatabase(async () => {
    const db = await import("../../src/db");
    const now = Date.now();
    await db.run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES ('acc_test_xu', 'xu', '小旭', 'unused', '', 'active', 0, ?, ?),
              ('acc_test_si', 'si', '小偲', 'unused', '', 'active', 0, ?, ?)`,
      [now, now, now, now],
    );
    const { ensureFixedCouple } = await import("../../src/auth/accounts");
    await ensureFixedCouple();
    await db.run(
      `INSERT INTO ai_memory
       (id, layer, scope, memory_key, subjects_json, speakers_json, content, category,
        confidence, importance, occurred_at, occurred_end_at, valid_from, valid_until,
        status, supersedes_id, metadata_json, embedding, created_at, updated_at,
        couple_id, owner_account_id, version)
       VALUES
       ('mem_state_old', 'state', 'couple', 'state.si.old', '["si"]', '[]', '旧近况', '',
        0.8, 3, NULL, NULL, ?, ?, 'active', NULL, '{}', NULL, ?, ?,
        'cpl_legacy_xusi', NULL, 0),
       ('mem_state_new', 'state', 'couple', 'state.si.new', '["si"]', '[]', '新近况', '',
        0.8, 3, NULL, NULL, ?, ?, 'active', NULL, '{}', NULL, ?, ?,
        'cpl_legacy_xusi', NULL, 0)`,
      [now, now + 60_000, now, now, now + 1, now + 120_000, now + 1, now + 1],
    );

    await db.migrate(db.databasePool(), 28);
    const rows = await db.all<{ id: string; status: string }>(
      "SELECT id, status FROM ai_memory WHERE id IN ('mem_state_old','mem_state_new') ORDER BY id",
    );
    assert.deepEqual(rows, [
      { id: "mem_state_new", status: "active" },
      { id: "mem_state_old", status: "superseded" },
    ]);
    await assert.rejects(() => db.run(
      `INSERT INTO ai_memory
       (id, layer, scope, memory_key, subjects_json, speakers_json, content, category,
        confidence, importance, status, metadata_json, created_at, updated_at, couple_id, version)
       VALUES ('mem_state_duplicate', 'state', 'couple', 'state.si.duplicate', '["si"]', '[]',
               '重复近况', '', 0.8, 3, 'active', '{}', ?, ?, 'cpl_legacy_xusi', 0)`,
      [now + 2, now + 2],
    ));
  }, { migrateThrough: 27 });
});
