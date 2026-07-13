import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("read receipts only move forward", async () => {
  await withTestDatabase(async () => {
    const { run } = await import("../../src/db");
    const { upsertReadReceipt } = await import("../../src/chat/messageService");
    const user = { username: "xu", name: "小旭" };
    const now = Date.now();
    await run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES ('acc_test_xu', 'xu', '小旭', 'unused', '', 'active', 0, ?, ?),
              ('acc_test_si', 'si', '小偲', 'unused', '', 'active', 0, ?, ?)`,
      [now, now, now, now],
    );
    const { ensureFixedCouple, ensureFixedConversations } = await import("../../src/auth/accounts");
    await ensureFixedCouple();
    await ensureFixedConversations();
    await run(
      `INSERT INTO messages (id, channel, sender, sender_name, kind, type, text, ts, conversation_id, sender_account_id)
       VALUES ('read-1', 'couple', 'si', '小偲', 'user', 'text', '', ?, 'conv_legacy_couple', 'acc_test_si'),
              ('read-2', 'couple', 'si', '小偲', 'user', 'text', '', ?, 'conv_legacy_couple', 'acc_test_si'),
              ('read-3', 'couple', 'si', '小偲', 'user', 'text', '', ?, 'conv_legacy_couple', 'acc_test_si')`,
      [now - 3_000, now - 2_000, now - 1_000],
    );

    assert.equal(await upsertReadReceipt(user, "couple", now - 2_000), now - 2_000);
    assert.equal(await upsertReadReceipt(user, "couple", now - 3_000), now - 2_000);
    assert.equal(await upsertReadReceipt(user, "couple", now + 86_400_000), now - 1_000);

    const { get } = await import("../../src/db");
    const receipt = await get<{ ts: number }>(
      "SELECT ts FROM read_receipts WHERE channel = ? AND username = ?",
      ["couple", "xu"],
    );
    assert.equal(receipt?.ts, now - 1_000);
  });
});
