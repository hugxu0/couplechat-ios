import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

async function listen(server: http.Server): Promise<number> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve(typeof address === "object" && address ? address.port : 0);
    });
  });
}

test("memory lifecycle renews validity, preserves editable history and rebuilds vectors immediately", async () => {
  let embeddingCalls = 0;
  const embeddingServer = http.createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      embeddingCalls += 1;
      const input = String((JSON.parse(body) as { input?: string[] }).input?.[0] ?? "");
      const embedding = input.includes("绿色") ? [1, 0] : [0, 1];
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ data: [{ embedding }] }));
    });
  });
  const port = await listen(embeddingServer);

  try {
    await withTestDatabase(async () => {
      const { all, get, run } = await import("../../src/db");
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
      const couple = await get<{ id: string }>("SELECT id FROM couples WHERE status = 'active' LIMIT 1");
      assert.ok(couple);

      const memory = await import("../../src/ai/memory/store");
      const firstPlan = await memory.addMemory({
        layer: "plan",
        scope: "couple",
        memoryKey: "plan.xu.clean_room",
        subjects: ["xu"],
        speakers: [],
        content: "小旭准备周末整理房间",
        validFrom: now,
        validUntil: now + 1_000,
      });
      const renewedPlan = await memory.addMemory({
        layer: "plan",
        scope: "couple",
        memoryKey: "plan.xu.clean_room",
        subjects: ["xu"],
        speakers: [],
        content: "小旭准备周末整理房间",
        validFrom: now + 10_000,
        validUntil: now + 100_000,
      });
      assert.equal(renewedPlan?.id, firstPlan?.id);
      assert.equal(renewedPlan?.validFrom, now + 10_000);
      assert.equal(renewedPlan?.validUntil, now + 100_000);

      const originalFact = await memory.addMemory({
        layer: "fact",
        scope: "couple",
        memoryKey: "fact.xu.favorite_color",
        subjects: ["xu"],
        speakers: [],
        content: "小旭喜欢蓝色",
      });
      assert.ok(originalFact);
      const editedFact = await memory.updateMemoryForControl({
        memoryId: originalFact.id,
        scopes: ["couple"],
        coupleId: couple.id,
        content: "小旭手动改为喜欢绿色",
        editor: "xu",
        editorAccountId: "acc_test_xu",
        baseVersion: 0,
      });
      assert.equal(editedFact?.content, "小旭手动改为喜欢绿色");
      const embedded = await get<{ bytes: number }>(
        "SELECT OCTET_LENGTH(embedding) AS bytes FROM ai_memory WHERE id = ?",
        [originalFact.id],
      );
      assert.equal(embedded?.bytes, 8);

      const automaticReplacement = await memory.addMemory({
        layer: "fact",
        scope: "couple",
        memoryKey: "model.generated.key",
        subjects: ["xu"],
        speakers: [],
        content: "小旭现在喜欢黄色",
        targetMemoryId: originalFact.id,
      });
      assert.equal(automaticReplacement?.content, "小旭现在喜欢黄色");
      assert.equal(automaticReplacement?.memoryKey, "fact.xu.favorite_color");
      assert.equal((await get<{ status: string }>(
        "SELECT status FROM ai_memory WHERE id = ?", [originalFact.id],
      ))?.status, "superseded");

      await memory.addMemory({
        layer: "state", scope: "couple", memoryKey: "state.si.legacy",
        subjects: ["si"], speakers: [], content: "小偲上午有点困",
        validFrom: now, validUntil: now + 60_000,
      });
      const latestState = await memory.addMemory({
        layer: "state", scope: "couple", memoryKey: "state.si.recent",
        subjects: ["si"], speakers: [], content: "小偲下午精神恢复了",
        validFrom: now + 1_000, validUntil: now + 120_000,
      });
      const activeStates = await all<{ id: string; content: string }>(
        `SELECT id, content FROM ai_memory
         WHERE layer = 'state' AND scope = 'couple' AND subjects_json = '["si"]' AND status = 'active'`,
      );
      assert.deepEqual(activeStates, [{ id: latestState?.id, content: "小偲下午精神恢复了" }]);
      assert.ok(embeddingCalls >= 6);
    }, {
      environment: {
        EMBEDDING_BASE_URL: `http://127.0.0.1:${port}`,
        EMBEDDING_API_KEY: "test-key",
        EMBEDDING_MODEL: "test-embedding",
        EMBEDDING_DIM: "2",
      },
    });
  } finally {
    await new Promise<void>((resolve) => embeddingServer.close(() => resolve()));
  }
});
