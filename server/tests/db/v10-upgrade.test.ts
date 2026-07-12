import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("v10 upgrade hard-deletes text and media recall tombstones safely", async () => {
  await withTestDatabase(async () => {
    const { databasePool, get, migrate, run } = await import("../../src/db");
    const now = Date.now();
    const file = path.join(process.env.UPLOAD_DIR!, "legacy-recalled.jpg");
    fs.writeFileSync(file, "legacy media payload");
    await run(
      `INSERT INTO accounts (username, display_name, password_hash, avatar, created_at, updated_at)
       VALUES ('xu', '小旭', 'unused', '', ?, ?),
              ('si', '小偲', 'unused', '', ?, ?)`,
      [now, now, now, now],
    );
    await run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, url, reply_json,
        meta_json, attachments_json, recalled_text, ts, client_id)
       VALUES
       ('old-text', 'couple', 'xu', '小旭', 'system', 'text', '你撤回了一条消息', NULL, NULL, NULL, NULL, '原文字', ?, 'client-text'),
       ('old-image', 'couple', 'xu', '小旭', 'system', 'text', '你撤回了一条消息', NULL, NULL, NULL, NULL, NULL, ?, 'client-image'),
       ('legit-system', 'couple', 'system', '系统', 'system', 'text', '系统维护', NULL, NULL, NULL, NULL, NULL, ?, NULL),
       ('reply', 'couple', 'xu', '小旭', 'user', 'text', '回复', NULL, ?, NULL, NULL, NULL, ?, NULL),
       ('invalid-reply', 'couple', 'xu', '小旭', 'user', 'text', '脏数据', NULL, 'not-json', NULL, NULL, NULL, ?, NULL)`,
      [now - 5, now - 4, now - 3, JSON.stringify({ id: "old-image", preview: "[图片]" }), now - 2, now - 1],
    );
    await run(
      `INSERT INTO uploads
       (id, owner, path, url, mime_type, size, created_at, message_id, purpose)
       VALUES ('legacy-upload', 'xu', ?, '/media/legacy-upload', 'image/jpeg', 20, ?, 'old-image', 'message')`,
      [file, now],
    );
    await run(
      `INSERT INTO ai_memory
       (id, layer, scope, memory_key, subjects_json, speakers_json, content,
        category, confidence, importance, status, metadata_json, created_at, updated_at)
       VALUES ('legacy-memory', 'event', 'couple', 'legacy.recalled.image', '["xu"]',
               '["xu"]', '旧图片原文派生', '', 0.8, 3, 'active', '{}', ?, ?)`,
      [now, now],
    );
    await run(
      `INSERT INTO ai_memory_evidence
       (memory_id, message_id, channel, sender, message_ts, excerpt, evidence_role, created_at)
       VALUES ('legacy-memory', 'old-image', 'couple', 'xu', ?, '旧图片原文派生', 'support', ?)`,
      [now - 4, now],
    );

    await migrate(databasePool());

    assert.equal(await get("SELECT id FROM messages WHERE id = 'old-text'"), undefined);
    assert.equal(await get("SELECT id FROM messages WHERE id = 'old-image'"), undefined);
    assert.ok(await get("SELECT id FROM messages WHERE id = 'legit-system'"));
    assert.equal((await get<{ reply_json: string | null }>(
      "SELECT reply_json FROM messages WHERE id = 'reply'",
    ))?.reply_json, null);
    assert.equal((await get<{ reply_json: string | null }>(
      "SELECT reply_json FROM messages WHERE id = 'invalid-reply'",
    ))?.reply_json, "not-json");
    assert.equal(await get("SELECT id FROM uploads WHERE id = 'legacy-upload'"), undefined);
    assert.equal(await get("SELECT id FROM ai_memory WHERE id = 'legacy-memory'"), undefined);
    assert.equal(fs.existsSync(file), true, "SQL migration must not perform filesystem IO");

    const { drainFileCleanupQueue } = await import("../../src/upload/cleanup");
    assert.equal(await drainFileCleanupQueue(), 1);
    assert.equal(fs.existsSync(file), false);
    assert.ok(await get(
      "SELECT id FROM file_cleanup_queue WHERE id = 'cleanup_legacy-upload' AND completed_at IS NOT NULL",
    ));
  }, { migrateThrough: 10 });
});
