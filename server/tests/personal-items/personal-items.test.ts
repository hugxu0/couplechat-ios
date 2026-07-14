import assert from "node:assert/strict";
import test from "node:test";
import type { Server } from "socket.io";
import { withTestDatabase } from "../support/postgresHarness";

test("personal items preserve visibility and complete the AI confirmation flow", async () => {
  await withTestDatabase(async () => {
    const items = await import("../../src/personalItems/itemService");
    const { get, run } = await import("../../src/db");
    const now = Date.now();
    await run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES (?, 'xu', '小旭', 'unused', '', 'active', 0, ?, ?),
              (?, 'si', '小偲', 'unused', '', 'active', 0, ?, ?)`,
      ["acc_test_xu", now, now, "acc_test_si", now, now],
    );
    const { ensureFixedCouple, ensureFixedConversations } = await import("../../src/auth/accounts");
    await ensureFixedCouple();
    await ensureFixedConversations();
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
    const routeItem = response.json().item as { id: string };
    const deletedRouteItem = await app.inject({
      method: "DELETE",
      url: `/api/me/items/${routeItem.id}`,
      headers: { authorization: `Bearer ${createToken(xu)}` },
    });
    assert.equal(deletedRouteItem.statusCode, 200);
    assert.equal(events.at(-1)?.action, "deleted");
    assert.equal((events.at(-1)?.item as { scope?: string })?.scope, "shared");

    const login = await app.inject({
      method: "POST",
      url: "/api/v2/login",
      payload: {
        username: "missing",
        password: "wrong",
        device: {
          installationId: "missing-account-test-device",
          platform: "ios",
          deviceName: "Test iPhone",
          appVersion: "1",
          buildNumber: "1",
          locale: "zh-CN",
          timezone: "Asia/Shanghai",
        },
      },
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
    recipients: async () => [{ username: "xu", barkKey: "bark-key", endpointKey: "endpoint-xu" }],
    claimDelivery: async () => "claim-1",
    finishDelivery: async () => undefined,
    push: async (_key, _title, body) => { pushes.push(body); },
  });
  await scheduler.scanOnce();
  scheduler.stop();
  assert.equal(pushes.length, 1);
  assert.match(pushes[0], /^喝水 · /);
});

test("shared reminders notify both accounts while private reminders notify only the owner", async () => {
  const { createReminderScheduler } = await import("../../src/personalItems/reminderScheduler");
  const pushes: string[] = [];
  const delivered = new Set<string>();
  const scheduler = createReminderScheduler({
    now: () => 2_000,
    dueReminders: async () => [
      {
        id: "shared", owner: "xu", kind: "reminder", scope: "shared", title: "一起出门",
        body_markdown: "", due_at: 1_500, is_done: 0, created_at: 1_000, updated_at: 1_000,
      },
      {
        id: "private", owner: "xu", kind: "reminder", scope: "personal", title: "私人事项",
        body_markdown: "", due_at: 1_600, is_done: 0, created_at: 1_000, updated_at: 1_000,
      },
    ],
    recipients: async (reminder) => reminder.scope === "shared"
      ? [
          { username: "xu", barkKey: "bark-xu", endpointKey: "endpoint-xu" },
          { username: "si", barkKey: "bark-si", endpointKey: "endpoint-si" },
        ]
      : [{ username: "xu", barkKey: "bark-xu", endpointKey: "endpoint-xu" }],
    claimDelivery: async (id, dueAt, recipient, endpoint) => {
      const key = `${id}:${dueAt}:${recipient}:${endpoint}`;
      return delivered.has(key) ? null : `claim:${key}`;
    },
    finishDelivery: async (id, dueAt, recipient, endpoint, _token, succeeded) => {
      if (succeeded) delivered.add(`${id}:${dueAt}:${recipient}:${endpoint}`);
    },
    push: async (key, _title, body) => { pushes.push(`${key}:${body}`); },
  });

  await scheduler.scanOnce();
  await scheduler.scanOnce();
  scheduler.stop();
  assert.equal(pushes.filter((item) => item.includes("一起出门")).length, 2);
  assert.deepEqual(
    pushes.filter((item) => item.includes("私人事项")).map((item) => item.split(":")[0]),
    ["bark-xu"],
  );
});

test("reminder delivery retries only the failed endpoint of one account", async () => {
  const { createReminderScheduler } = await import("../../src/personalItems/reminderScheduler");
  const delivered = new Set<string>();
  const attempts = new Map<string, number>();
  const reminder = {
    id: "multi-device", owner: "xu", kind: "reminder", scope: "personal", title: "多设备",
    body_markdown: "", due_at: 1_500, is_done: 0, created_at: 1_000, updated_at: 1_000,
  };
  const scheduler = createReminderScheduler({
    now: () => 2_000,
    dueReminders: async () => [reminder],
    recipients: async () => [
      { username: "xu", barkKey: "phone", endpointKey: "endpoint-phone" },
      { username: "xu", barkKey: "tablet", endpointKey: "endpoint-tablet" },
    ],
    claimDelivery: async (id, dueAt, recipient, endpoint) => {
      const key = `${id}:${dueAt}:${recipient}:${endpoint}`;
      return delivered.has(key) ? null : `claim:${key}`;
    },
    finishDelivery: async (id, dueAt, recipient, endpoint, _token, succeeded) => {
      if (succeeded) delivered.add(`${id}:${dueAt}:${recipient}:${endpoint}`);
    },
    push: async (key) => {
      const count = (attempts.get(key) ?? 0) + 1;
      attempts.set(key, count);
      if (key === "tablet" && count === 1) throw new Error("temporary failure");
    },
  });

  await scheduler.scanOnce();
  await scheduler.scanOnce();
  scheduler.stop();
  assert.equal(attempts.get("phone"), 1);
  assert.equal(attempts.get("tablet"), 2);
});

async function verifyAIConfirmationFlow() {
    const { get, run } = await import("../../src/db");
    const { applyAction, confirmAction } = await import("../../src/ai/actions/personalItems");
    const { createPersonalItem, getPersonalItem, listPersonalItems } = await import("../../src/personalItems/itemService");
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
       (id, channel, sender, sender_name, kind, type, text, meta_json, ts, conversation_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'conv_legacy_ai_xu')`,
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

    assert.deepEqual(
      await confirmAction(io, { username: "si", name: "小偲" }, "ai-confirm-1", "confirm"),
      { ok: false },
    );
    const concurrentResults = await Promise.all([
      confirmAction(io, { username: "xu", name: "小旭" }, "ai-confirm-1", "confirm"),
      confirmAction(io, { username: "xu", name: "小旭" }, "ai-confirm-1", "confirm"),
    ]);
    assert.equal(concurrentResults.filter((result) => result.ok).length, 1);
    const memos = await listPersonalItems({ username: "xu", name: "小旭" }, "memo", "personal");
    assert.equal(memos.length, 1);
    assert.equal(memos[0].title, "日常小确幸记录表");
    assert.match(memos[0].bodyMarkdown, /^\| 日期 \|/);
    assert.doesNotMatch(memos[0].bodyMarkdown, /日常小确幸记录表/);
    assert.ok(emissions.some((entry) => entry.room === "account:acc_test_xu" && entry.event === "personalItem:changed"));
    assert.ok(emissions.some((entry) => {
      const payload = entry.payload as { meta?: { confirm?: { status?: string } } };
      return entry.room === "account:acc_test_xu"
        && entry.event === "message:update"
        && payload.meta?.confirm?.status === "confirmed";
    }));

    const reminder = await createPersonalItem(
      { username: "xu", name: "小旭" },
      { kind: "reminder", scope: "personal", title: "旧提醒", dueAt: null },
    );
    assert.ok(reminder);
    assert.equal((await applyAction({
      type: "edit_reminder",
      id: reminder!.id,
      newTitle: "新的提醒",
      newTime: "2026-07-15 08:30",
      scope: "personal",
    }, { requesterUsername: "xu" })).ok, true);
    const editedReminder = await getPersonalItem({ username: "xu", name: "小旭" }, reminder!.id);
    assert.equal(editedReminder?.title, "新的提醒");
    assert.equal(editedReminder?.dueAt, Date.parse("2026-07-15T08:30:00+08:00"));

    const removableMemo = await createPersonalItem(
      { username: "xu", name: "小旭" },
      { kind: "memo", scope: "personal", title: "稍后删除" },
    );
    assert.ok(removableMemo);
    assert.equal((await applyAction({
      type: "delete_memo", id: removableMemo!.id, scope: "personal",
    }, { requesterUsername: "xu" })).ok, true);
    assert.equal(await getPersonalItem({ username: "xu", name: "小旭" }, removableMemo!.id), null);

    const partnersPrivateMemo = await createPersonalItem(
      { username: "si", name: "小偲" },
      { kind: "memo", scope: "personal", title: "对方私密备忘" },
    );
    assert.ok(partnersPrivateMemo);
    assert.equal((await applyAction({
      type: "delete_memo", id: partnersPrivateMemo!.id, ownerName: "小偲", scope: "personal",
    }, { requesterUsername: "xu" })).ok, false);

    const rejectedConfirm = {
      ...confirm,
      status: "pending",
      items: [{
        label: "不支持的操作",
        action: { type: "unsupported_action" },
      }],
    };
    await run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, meta_json, ts, conversation_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'conv_legacy_ai_xu')`,
      ["ai-confirm-2", "ai:xu", "ai", "大橘", "ai", "text", "请确认", JSON.stringify({ confirm: rejectedConfirm }), Date.now()],
    );
    assert.deepEqual(
      await confirmAction(io, { username: "xu", name: "小旭" }, "ai-confirm-2", "confirm"),
      { ok: true },
    );
    const rejectedRow = await get<{ meta_json: string }>(
      "SELECT meta_json FROM messages WHERE id = ?",
      ["ai-confirm-2"],
    );
    const rejectedMeta = JSON.parse(rejectedRow?.meta_json ?? "{}") as {
      confirm?: { status?: string; failed?: number; items?: Array<{ result?: string; error?: string }> };
    };
    assert.equal(rejectedMeta.confirm?.status, "confirmed");
    assert.equal(rejectedMeta.confirm?.failed, 1);
    assert.equal(rejectedMeta.confirm?.items?.[0]?.result, "failed");
    assert.equal(rejectedMeta.confirm?.items?.[0]?.error, "action_rejected");
}
