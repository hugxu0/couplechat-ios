import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("daily recommendations use shared experience cards and keep deletable per-user history", async () => {
  await withTestDatabase(async () => {
    const { buildApp } = await import("../../src/app");
    const { all, run } = await import("../../src/db");
    const { ensureFixedConversations, ensureFixedCouple } = await import("../../src/auth/accounts");
    const { createToken } = await import("../../src/auth/token");
    const { addMemory } = await import("../../src/ai/memory/store");
    const { addDays, cycleBounds, cycleDate } = await import("../../src/ai/time");
    const {
      parseGeneratedRecommendation,
      recommendationMemoryIds,
    } = await import("../../src/daily/recommendationService");
    const now = Date.now();
    assert.deepEqual(
      parseGeneratedRecommendation(
        '{"category":"城市漫游","content":"推荐沿着一条旧街区路线慢慢走，挑一家顺眼的小店坐下来。"}',
      ),
      {
        category: "城市漫游",
        content: "推荐沿着一条旧街区路线慢慢走，挑一家顺眼的小店坐下来。",
      },
      "category labels are open text rather than a fixed enum",
    );
    await run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES ('acc_legacy_xu', 'xu', '小旭', 'unused', '', 'active', 0, ?, ?),
              ('acc_legacy_si', 'si', '小偲', 'unused', '', 'active', 0, ?, ?)`,
      [now, now, now, now],
    );
    await ensureFixedCouple();
    await ensureFixedConversations();

    const yesterday = cycleBounds(addDays(cycleDate(), -1));
    const experience = await addMemory({
      layer: "event", scope: "couple", memoryKey: "event.both.yesterday_walk",
      subjects: ["both"], speakers: ["xu", "si"],
      content: "小旭和小偲昨天傍晚一起散步，觉得河边很安静。",
      occurredAt: yesterday.start + 60 * 60 * 1_000, importance: 4,
    });
    const fact = await addMemory({
      layer: "fact", scope: "couple", memoryKey: "fact.both.quiet_places",
      subjects: ["both"], speakers: ["xu"], content: "两个人都喜欢安静的地方。", importance: 4,
    });
    const relationship = experience && fact ? await addMemory({
      layer: "relationship", scope: "couple", memoryKey: "relationship.both.current",
      subjects: ["both"], speakers: [], content: "两个人最近通过散步保持亲近。",
      sourceMemoryIds: [experience.id, fact.id], importance: 4,
    }) : null;
    assert.ok(experience && fact && relationship);

    const app = await buildApp();
    const xuToken = createToken({ username: "xu", name: "小旭" });
    const siToken = createToken({ username: "si", name: "小偲" });
    const auth = (token: string) => ({ authorization: `Bearer ${token}` });

    const xuToday = await app.inject({
      method: "GET", url: "/api/v2/recommendations/today", headers: auth(xuToken),
    });
    assert.equal(xuToday.statusCode, 200, xuToday.body);
    assert.equal(xuToday.json().daju.sourceKind, "daju");
    assert.ok(typeof xuToday.json().daju.category === "string");
    assert.ok(xuToday.json().daju.category.length > 0, "Daju picks an open category label");
    assert.doesNotMatch(
      xuToday.json().daju.content,
      /提醒|待办|列成一页|整理照片/,
      "Daju recommends a concrete thing instead of repackaging chores",
    );
    const dailyId = xuToday.json().daju.id as string;
    const memoryIds = await recommendationMemoryIds(dailyId);
    assert.ok(memoryIds.includes(experience.id));
    assert.ok(memoryIds.includes(fact.id));
    assert.ok(!memoryIds.includes(relationship.id), "relationship and insight layers are never recommendation inputs");

    await run(
      "UPDATE recommendations SET category = NULL, content = '整理提醒和待办事项' WHERE id = ?",
      [dailyId],
    );
    const upgradedToday = await app.inject({
      method: "GET", url: "/api/v2/recommendations/today", headers: auth(xuToken),
    });
    assert.equal(upgradedToday.json().daju.id, dailyId, "legacy daily rows upgrade in place");
    assert.ok(upgradedToday.json().daju.category);
    assert.doesNotMatch(upgradedToday.json().daju.content, /整理|提醒|待办/);

    const siToday = await app.inject({
      method: "GET", url: "/api/v2/recommendations/today", headers: auth(siToken),
    });
    assert.equal(siToday.json().daju.id, dailyId, "both people share the same Daju recommendation");
    assert.equal(siToday.json().daju.content, upgradedToday.json().daju.content);

    const first = await app.inject({
      method: "POST", url: "/api/v2/recommendations", headers: auth(xuToken),
      payload: { content: "今天下班后一起吃冰淇淋吧。" },
    });
    const second = await app.inject({
      method: "POST", url: "/api/v2/recommendations", headers: auth(xuToken),
      payload: { content: "改成一起去买草莓。" },
    });
    assert.equal(first.statusCode, 201, first.body);
    assert.equal(second.statusCode, 201, second.body);
    const firstId = first.json().recommendation.id as string;
    const secondId = second.json().recommendation.id as string;
    const unread = await app.inject({
      method: "GET", url: "/api/v2/recommendations/unread-count", headers: auth(siToken),
    });
    assert.equal(unread.json().unreadCount, 2);
    const latest = await app.inject({
      method: "GET", url: "/api/v2/recommendations/today", headers: auth(siToken),
    });
    assert.equal(latest.json().partner.id, secondId);
    assert.equal(latest.json().latestUnread.id, secondId);

    const read = await app.inject({
      method: "POST", url: `/api/v2/recommendations/${secondId}/read`, headers: auth(siToken),
    });
    assert.equal(read.statusCode, 200, read.body);
    assert.equal((await app.inject({
      method: "GET", url: "/api/v2/recommendations/unread-count", headers: auth(siToken),
    })).json().unreadCount, 0, "accepting the latest recommendation reads every older pending one");

    const siHistoryBefore = await app.inject({
      method: "GET", url: "/api/v2/recommendations/history", headers: auth(siToken),
    });
    assert.ok(siHistoryBefore.json().recommendations.some((item: { id: string }) => item.id === firstId));
    const deleted = await app.inject({
      method: "DELETE", url: `/api/v2/recommendations/${firstId}`, headers: auth(siToken),
    });
    assert.equal(deleted.statusCode, 200, deleted.body);
    const siHistoryAfter = await app.inject({
      method: "GET", url: "/api/v2/recommendations/history", headers: auth(siToken),
    });
    assert.ok(!siHistoryAfter.json().recommendations.some((item: { id: string }) => item.id === firstId));
    const xuHistory = await app.inject({
      method: "GET", url: "/api/v2/recommendations/history", headers: auth(xuToken),
    });
    assert.ok(xuHistory.json().recommendations.some((item: { id: string }) => item.id === firstId),
      "history deletion only removes the current user's copy");

    const refreshed = await app.inject({
      method: "POST", url: "/api/v2/recommendations/refresh", headers: auth(xuToken),
    });
    assert.equal(refreshed.statusCode, 201, refreshed.body);
    assert.notEqual(refreshed.json().recommendation.id, dailyId);
    const siAfterRefresh = await app.inject({
      method: "GET", url: "/api/v2/recommendations/today", headers: auth(siToken),
    });
    assert.equal(siAfterRefresh.json().daju.id, refreshed.json().recommendation.id);

    const syncTypes = new Set((await all<{ entity_type: string }>(
      "SELECT entity_type FROM sync_events ORDER BY seq",
    )).map((row) => row.entity_type));
    assert.ok(syncTypes.has("recommendation"));
    assert.ok(syncTypes.has("recommendation_state"));
    await app.close();
  });
});
