import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("personal items preserve owner isolation and shared visibility", async () => {
  await withTestDatabase(async () => {
    const items = await import("../../src/personalItems/itemService");
    const xu = { username: "xu", name: "小旭" };
    const si = { username: "si", name: "小偲" };
    const personal = await items.createPersonalItem(xu, { kind: "memo", title: "私有备忘" });
    const shared = await items.createPersonalItem(xu, { kind: "reminder", scope: "shared", title: "共同提醒" });

    assert.ok(personal);
    assert.ok(shared);
    assert.equal((await items.listPersonalItems(si, "memo", "personal")).length, 0);
    assert.equal((await items.listPersonalItems(si, "reminder", "shared"))[0]?.id, shared?.id);
    assert.equal((await items.updatePersonalItem(si, shared!.id, { isDone: true }))?.isDone, true);
    assert.equal(await items.deletePersonalItem(xu, personal!.id), true);
    assert.equal(await items.getPersonalItem(xu, personal!.id), null);

    const events: Array<{ action: string; item: unknown }> = [];
    const { buildApp } = await import("../../src/app");
    const { createToken } = await import("../../src/auth/token");
    const app = await buildApp({
      personalItemEvents: {
        sharedItemChanged: (action, item) => { events.push({ action, item }); },
      },
    });
    const response = await app.inject({
      method: "POST",
      url: "/api/me/items",
      headers: { authorization: `Bearer ${createToken(xu)}` },
      payload: { kind: "memo", scope: "shared", title: "路由广播测试" },
    });
    await app.close();
    assert.equal(response.statusCode, 201);
    assert.equal(events[0]?.action, "created");
    assert.equal((events[0]?.item as { scope?: string })?.scope, "shared");
  });
});

test("reminder scheduler uses injected clock, repository and push gateway", async () => {
  const { createReminderScheduler } = await import("../../src/personalItems/reminderScheduler");
  const pushes: string[] = [];
  const scheduler = createReminderScheduler({
    now: () => 2_000,
    dueReminders: async () => [{
      id: "reminder_1", owner: "xu", kind: "reminder", scope: "personal", title: "喝水",
      body_markdown: "", due_at: 1_500, is_done: 0, created_at: 1_000, updated_at: 1_000,
    }],
    account: async () => ({
      username: "xu", display_name: "小旭", password_hash: "hash", avatar: "", bark_key: "bark-key",
      created_at: 1_000, updated_at: 1_000,
    }),
    push: async (_key, _title, body) => { pushes.push(body); },
  });
  await scheduler.scanOnce();
  scheduler.stop();
  assert.equal(pushes.length, 1);
  assert.match(pushes[0], /^喝水 · /);
});
