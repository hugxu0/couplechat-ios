import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("memory control routes isolate private scope and support review actions", async () => {
  await withTestDatabase(async () => {
    const { run } = await import("../../src/db");
    const { addMemory } = await import("../../src/ai/memory/store");
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
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, ts, conversation_id, sender_account_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'conv_legacy_couple', 'acc_test_xu'),
              (?, ?, ?, ?, ?, ?, ?, ?, 'conv_legacy_ai_xu', 'acc_test_xu')`,
      [
        "memory-source-shared", "couple", "xu", "小旭", "user", "text", "我们喜欢海边", now,
        "memory-source-private", "ai:xu", "xu", "小旭", "user", "text", "我准备一个惊喜", now + 1,
      ],
    );
    const shared = await addMemory({
      layer: "fact", scope: "couple", memoryKey: "likes.seaside", subjects: ["xu", "si"],
      speakers: ["xu"], content: "两个人都喜欢去海边", sourceMessageIds: ["memory-source-shared"],
    });
    const privateItem = await addMemory({
      layer: "plan", scope: "ai:xu", memoryKey: "surprise", subjects: ["xu"],
      speakers: ["xu"], content: "小旭准备了一个惊喜", sourceMessageIds: ["memory-source-private"],
    });
    assert.ok(shared && privateItem);

    const { buildApp } = await import("../../src/app");
    const { createToken } = await import("../../src/auth/token");
    const app = await buildApp();
    const xuToken = createToken({ username: "xu", name: "小旭" });
    const siToken = createToken({ username: "si", name: "小偲" });

    const xuList = await app.inject({
      method: "GET", url: "/api/me/memory?scope=all",
      headers: { authorization: `Bearer ${xuToken}` },
    });
    assert.equal(xuList.statusCode, 200);
    assert.deepEqual(
      new Set(xuList.json().items.map((item: { id: string }) => item.id)),
      new Set([shared!.id, privateItem!.id]),
    );

    const siList = await app.inject({
      method: "GET", url: "/api/me/memory?scope=all",
      headers: { authorization: `Bearer ${siToken}` },
    });
    assert.deepEqual(siList.json().items.map((item: { id: string }) => item.id), [shared!.id]);

    const corrected = await app.inject({
      method: "PATCH", url: `/api/me/memory/${shared!.id}`,
      headers: { authorization: `Bearer ${xuToken}` },
      payload: { content: "我们都喜欢安静的海边", importance: 5, baseVersion: 0 },
    });
    assert.equal(corrected.statusCode, 200);
    assert.equal(corrected.json().item.content, "我们都喜欢安静的海边");
    assert.equal(corrected.json().item.importance, 5);
    assert.ok(corrected.json().item.version > 0);

    const staleUpdate = await app.inject({
      method: "PATCH", url: `/api/me/memory/${shared!.id}`,
      headers: { authorization: `Bearer ${siToken}` },
      payload: { content: "旧设备覆盖", baseVersion: 0 },
    });
    assert.equal(staleUpdate.statusCode, 409);

    const evidence = await app.inject({
      method: "GET", url: `/api/me/memory/${shared!.id}/evidence`,
      headers: { authorization: `Bearer ${xuToken}` },
    });
    assert.equal(evidence.json().evidence[0].messageId, "memory-source-shared");

    const forbiddenDelete = await app.inject({
      method: "DELETE", url: `/api/me/memory/${privateItem!.id}`,
      headers: { authorization: `Bearer ${siToken}` },
    });
    assert.equal(forbiddenDelete.statusCode, 404);

    const deleted = await app.inject({
      method: "DELETE", url: `/api/me/memory/${privateItem!.id}`,
      headers: { authorization: `Bearer ${xuToken}` },
    });
    assert.equal(deleted.statusCode, 200);
    assert.equal(await addMemory({
      layer: "plan", scope: "ai:xu", memoryKey: "surprise", subjects: ["xu"],
      speakers: ["xu"], content: "小旭准备了一个惊喜", sourceMessageIds: ["memory-source-private"],
    }), null);
    await app.close();
  });
});
