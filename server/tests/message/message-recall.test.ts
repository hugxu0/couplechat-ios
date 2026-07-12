import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("recall hard-deletes the message, derivatives and orphan memory", async () => {
  await withTestDatabase(async () => {
    const { get, run } = await import("../../src/db");
    const now = Date.now();
    await run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES ('acc_test_xu', 'xu', '小旭', 'unused', '', 'active', 0, ?, ?),
              ('acc_test_si', 'si', '小偲', 'unused', '', 'active', 0, ?, ?)`,
      [now, now, now, now],
    );
    const { ensureLegacyCouple, ensureLegacyConversations } = await import("../../src/auth/accounts");
    await ensureLegacyCouple();
    await ensureLegacyConversations();
    await run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, url, ts, conversation_id, sender_account_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'conv_legacy_couple', 'acc_test_xu'),
              (?, ?, ?, ?, ?, ?, ?, ?, ?, 'conv_legacy_couple', 'acc_test_si'),
              (?, ?, ?, ?, ?, ?, ?, ?, ?, 'conv_legacy_couple', 'acc_test_si')`,
      [
        "message-to-recall", "couple", "xu", "小旭", "user", "image", "[图片]", "/media/upload-1", now,
        "message-reply", "couple", "si", "小偲", "user", "text", "回复", null, now + 1,
        "invalid-reply", "couple", "si", "小偲", "user", "text", "脏引用", null, now + 2,
      ],
    );
    await run(
      "UPDATE messages SET reply_json = ? WHERE id = ?",
      [JSON.stringify({ id: "message-to-recall", preview: "[图片]" }), "message-reply"],
    );
    await run("UPDATE messages SET reply_json = 'not-json' WHERE id = 'invalid-reply'");
    await run(
      `INSERT INTO uploads
       (id, owner, path, url, mime_type, size, created_at, message_id, purpose)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["upload-1", "xu", "missing-recalled-file.jpg", "/media/upload-1", "image/jpeg", 12, now, "message-to-recall", "message"],
    );
    await run(
      `INSERT INTO message_attachments (id, message_id, upload_id, asset_id, role, sort_order)
       VALUES (?, ?, ?, ?, ?, ?)`,
      ["attachment-1", "message-to-recall", "upload-1", "asset-1", "photo", 0],
    );

    const { addMemory } = await import("../../src/ai/memory/store");
    const memory = await addMemory({
      layer: "event", scope: "couple", memoryKey: "recalled.photo", subjects: ["xu"],
      speakers: ["xu"], content: "小旭发过一张照片", sourceMessageIds: ["message-to-recall"],
    });
    assert.ok(memory);

    const { recallMessage } = await import("../../src/chat/messageService");
    const result = await recallMessage({ username: "xu", name: "小旭" }, "message-to-recall");
    assert.equal(result?.deleted, true);
    assert.equal("recalledText" in (result ?? {}), false);
    assert.equal(await get("SELECT id FROM messages WHERE id = ?", ["message-to-recall"]), undefined);
    assert.equal(await get("SELECT id FROM uploads WHERE id = ?", ["upload-1"]), undefined);
    assert.ok(await get(
      "SELECT id FROM file_cleanup_queue WHERE id = 'cleanup_upload-1' AND completed_at IS NOT NULL",
    ));
    assert.equal(await get("SELECT id FROM message_attachments WHERE id = ?", ["attachment-1"]), undefined);
    assert.equal(await get("SELECT id FROM ai_memory WHERE id = ?", [memory!.id]), undefined);
    assert.ok(await get(
      "SELECT seq FROM sync_events WHERE entity_type = 'message' AND entity_id = ? AND operation = 'delete'",
      ["message-to-recall"],
    ));
    const reply = await get<{ reply_json: string | null }>(
      "SELECT reply_json FROM messages WHERE id = ?", ["message-reply"],
    );
    assert.equal(reply?.reply_json, null);
    assert.equal((await get<{ reply_json: string }>(
      "SELECT reply_json FROM messages WHERE id = 'invalid-reply'",
    ))?.reply_json, "not-json");
    assert.equal(await recallMessage({ username: "xu", name: "小旭" }, "message-reply"), null);

    await run(
      `INSERT INTO messages (id, channel, sender, sender_name, kind, type, text, ts)
       VALUES ('too-old', 'couple', 'xu', '小旭', 'user', 'text', '不能再撤回', ?)`,
      [Date.now() - 120_001],
    );
    await assert.rejects(
      recallMessage({ username: "xu", name: "小旭" }, "too-old"),
      /recall_window_expired/,
    );
  });
});
