import assert from "node:assert/strict";
import test from "node:test";
import type { Server } from "socket.io";
import { withTestDatabase } from "../support/postgresHarness";

test("personal items preserve visibility and complete the AI confirmation flow", async () => {
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
    assert.equal(response.statusCode, 201);
    assert.equal(events[0]?.action, "created");
    assert.equal((events[0]?.item as { scope?: string })?.scope, "shared");

    const login = await app.inject({
      method: "POST",
      url: "/api/login",
      payload: { username: "missing", password: "wrong" },
    });
    assert.equal(login.statusCode, 401);
    assert.equal(login.json().error, "invalid_credentials");
    await verifyAIConfirmationFlow();
    await app.close();
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

async function verifyAIConfirmationFlow() {
    const { run } = await import("../../src/db");
    const { confirmAction } = await import("../../src/ai/actions/personalItems");
    const { listPersonalItems } = await import("../../src/personalItems/itemService");
    const confirm = {
      status: "pending",
      items: [{
        label: "备忘：日常小确幸记录表",
        action: {
          type: "add_memo",
          title: "日常小确幸记录表",
          text: "# 日常小确幸记录表\n\n| 日期 | 心情 |\n| --- | --- |\n| 7/12 | 开心 |",
          scope: "personal",
        },
      }],
      requesterName: "小旭",
      requesterUsername: "xu",
    };
    await run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, meta_json, ts)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ["ai-confirm-1", "ai:xu", "ai", "大橘", "ai", "text", "请确认", JSON.stringify({ confirm }), Date.now()],
    );

    const emissions: Array<{ room: string; event: string; payload: unknown }> = [];
    const io = {
      to(room: string) {
        return {
          emit(event: string, payload: unknown) {
            emissions.push({ room, event, payload });
          },
        };
      },
    } as unknown as Server;

    assert.deepEqual(await confirmAction(io, "ai-confirm-1", "confirm"), { ok: true });
    const memos = await listPersonalItems({ username: "xu", name: "小旭" }, "memo", "personal");
    assert.equal(memos.length, 1);
    assert.equal(memos[0].title, "日常小确幸记录表");
    assert.match(memos[0].bodyMarkdown, /^\| 日期 \|/);
    assert.doesNotMatch(memos[0].bodyMarkdown, /日常小确幸记录表/);
    assert.ok(emissions.some((entry) => entry.room === "user:xu" && entry.event === "personalItem:changed"));
    assert.ok(emissions.some((entry) => {
      const payload = entry.payload as { meta?: { confirm?: { status?: string } } };
      return entry.room === "user:xu"
        && entry.event === "message:update"
        && payload.meta?.confirm?.status === "confirmed";
    }));
}
