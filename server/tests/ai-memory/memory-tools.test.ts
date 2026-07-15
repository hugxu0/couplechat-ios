import assert from "node:assert/strict";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { withTestDatabase } from "../support/postgresHarness";
import type { AgentToolRun } from "../../src/ai/mcp/runContext";

function toolJson(result: Awaited<ReturnType<Client["callTool"]>>): Record<string, any> {
  const first = result.content[0];
  assert.equal(first?.type, "text");
  return JSON.parse("text" in first ? first.text : "{}");
}

test("layered memory MCP tools include Daju instructions and observations", async () => {
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
    const { ensureFixedCouple, ensureFixedConversations } = await import("../../src/auth/accounts");
    await ensureFixedCouple();
    await ensureFixedConversations();
    const { loadAccounts } = await import("../../src/ai/accounts");
    await loadAccounts();
    const memory = await import("../../src/ai/memory/store");

    const xuFact = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "fact.xu.color",
      subjects: ["xu"], speakers: [], content: "小旭长期喜欢蓝色", importance: 4,
    });
    const siFact = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "fact.si.color",
      subjects: ["si"], speakers: [], content: "小偲长期喜欢绿色", importance: 4,
    });
    const sharedFact = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "fact.both.seaside",
      subjects: ["both"], speakers: [], content: "两个人都喜欢安静的海边", importance: 5,
    });
    assert.ok(xuFact && siFact && sharedFact);

    const beijingStart = Date.UTC(2026, 6, 14, 16, 0, 0);
    await memory.addMemory({
      layer: "event", scope: "couple", memoryKey: "event.xu.boundary_walk",
      subjects: ["xu"], speakers: [], content: "小旭完成了边界散步",
      occurredAt: beijingStart - 30 * 60_000,
    });
    await memory.addMemory({
      layer: "event", scope: "couple", memoryKey: "event.si.boundary_walk",
      subjects: ["si"], speakers: [], content: "小偲完成了边界散步",
      occurredAt: beijingStart + 30 * 60_000,
      occurredEndAt: beijingStart + 90 * 60_000,
    });
    await memory.addMemory({
      layer: "event", scope: "couple", memoryKey: "event.both.boundary_walk",
      subjects: ["both"], speakers: [], content: "两个人一起完成了边界散步",
      occurredAt: beijingStart + 60 * 60_000,
    });
    await memory.addMemory({
      layer: "plan", scope: "couple", memoryKey: "plan.xu.trip",
      subjects: ["xu"], speakers: [], content: "小旭准备旅行",
      validFrom: now, validUntil: now + 30 * 86400000,
    });
    await memory.addMemory({
      layer: "plan", scope: "couple", memoryKey: "plan.si.trip",
      subjects: ["si"], speakers: [], content: "小偲准备旅行",
      validFrom: now, validUntil: now + 30 * 86400000,
    });
    await memory.addMemory({
      layer: "state", scope: "couple", memoryKey: "state.xu.recent",
      subjects: ["xu"], speakers: [], content: "小旭最近在认真复习",
      validFrom: now, validUntil: now + 72 * 60 * 60 * 1000,
    });
    await memory.addMemory({
      layer: "state", scope: "couple", memoryKey: "state.si.recent",
      subjects: ["si"], speakers: [], content: "小偲最近在准备课程",
      validFrom: now + 1, validUntil: now + 72 * 60 * 60 * 1000,
    });
    await memory.addMemory({
      layer: "relationship", scope: "couple", memoryKey: "relationship.both.recent",
      subjects: ["both"], speakers: [], content: "两个人最近会耐心讨论分歧",
      sourceMemoryIds: [sharedFact.id], validFrom: now,
    });
    await memory.addMemory({
      layer: "insight", scope: "couple", memoryKey: "insight.both.interaction",
      subjects: ["both"], speakers: [], content: "提前说明需求有助于减少误会",
      sourceMemoryIds: [xuFact.id, siFact.id, sharedFact.id], validFrom: now,
    });
    const dajuInstruction = await memory.addMemory({
      layer: "fact", perspective: "daju", kind: "instruction", scope: "couple",
      memoryKey: "daju.instruction.reply_style", subjects: ["both"], speakers: [],
      content: "两位主人都希望大橘回答简短一些", importance: 5,
    });
    const dajuObservation = await memory.addMemory({
      layer: "insight", perspective: "daju", kind: "observation", scope: "couple",
      memoryKey: "daju.observation.conflict", subjects: ["both"], speakers: [],
      content: "两位主人出现分歧时，先复述双方观点通常更容易继续沟通",
      sourceMemoryIds: [xuFact.id, siFact.id, sharedFact.id], validFrom: now,
    });
    assert.ok(dajuInstruction && dajuObservation);
    const defaultFacts = await memory.searchMemory({
      query: "回答简短", layers: ["fact"], scopes: ["couple"],
    });
    assert.equal(defaultFacts.some((item) => item.id === dajuInstruction.id), false);

    const trace = {
      id: "memory-tools-test",
      ts: now,
      status: "running" as const,
      channel: "couple",
      requesterName: "小旭",
      question: "测试记忆工具",
    };
    const toolRun: AgentToolRun = {
      identity: {
        traceId: trace.id,
        requesterUsername: "xu",
        requesterName: "小旭",
        storedChannel: "couple",
        allowDajuInstructionWrite: true,
        expiresAt: now + 60_000,
      },
      trace,
      actions: [],
      citations: [],
      usedVision: false,
      toolCounts: {},
    };
    const { createCoupleChatMcpServer } = await import("../../src/ai/mcp/server");
    const server = createCoupleChatMcpServer(toolRun);
    const client = new Client({ name: "memory-tools-test", version: "1.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    await client.connect(clientTransport);

    try {
      const names = new Set((await client.listTools()).tools.map((tool) => tool.name));
      assert.ok(names.has("search_facts"));
      assert.ok(names.has("search_events"));
      assert.ok(names.has("search_plans"));
      assert.ok(names.has("get_current_states"));
      assert.ok(names.has("get_relationship_context"));
      assert.ok(names.has("get_current_insight"));
      assert.ok(names.has("get_daju_instructions"));
      assert.ok(names.has("get_daju_observations"));
      assert.ok(names.has("save_daju_instruction"));
      assert.equal(names.has("search_insights"), false);

      const events = toolJson(await client.callTool({
        name: "search_events",
        arguments: { query: "边界散步", subject: "小偲", fromDate: "2026-07-15", toDate: "2026-07-15" },
      }));
      assert.equal(events.returnedCount, 2);
      assert.ok(events.events.every((item: any) => item.subjects[0] === "si" || item.subjects[0] === "both"));
      assert.ok(events.events.some((item: any) => item.occurredEndTime));
      assert.ok(events.events.every((item: any) => item.updatedTime && !("metadata" in item)));

      const plans = toolJson(await client.callTool({
        name: "search_plans", arguments: { query: "准备旅行", subject: "小旭" },
      }));
      assert.equal(plans.returnedCount, 1);
      assert.deepEqual(plans.plans[0].subjects, ["xu"]);
      assert.ok(plans.plans[0].memoryValidUntilTime);

      const states = toolJson(await client.callTool({
        name: "get_current_states", arguments: { subject: "小偲" },
      }));
      assert.equal(states.returnedCount, 1);
      assert.deepEqual(states.states[0].subjectNames, ["小偲"]);

      const relationship = toolJson(await client.callTool({
        name: "get_relationship_context", arguments: {},
      }));
      assert.equal(relationship.returnedCount, 1);

      const insight = toolJson(await client.callTool({
        name: "get_current_insight", arguments: {},
      }));
      assert.equal(insight.returnedCount, 1);
      assert.match(insight.warning, /假设/);

      const instructions = toolJson(await client.callTool({
        name: "get_daju_instructions", arguments: {},
      }));
      assert.equal(instructions.returnedCount, 1);
      assert.equal(instructions.instructions[0].kind, "instruction");

      const savedInstruction = toolJson(await client.callTool({
        name: "save_daju_instruction",
        arguments: {
          topic: "称呼方式",
          instruction: "和小旭说话时称呼他为爸爸",
          appliesTo: "current_user",
        },
      }));
      assert.equal(savedInstruction.saved, true);
      assert.deepEqual(savedInstruction.instruction.subjects, ["xu"]);
      const directInstructions = await memory.searchMemory({
        query: "称呼爸爸",
        layers: ["fact"],
        scopes: ["couple"],
        perspectives: ["daju"],
        kinds: ["instruction"],
      });
      assert.ok(directInstructions.some((item) => item.content.includes("称呼他为爸爸")));
      const syncEvent = await get<{ count: number }>(
        "SELECT COUNT(*) AS count FROM sync_events WHERE entity_type = 'memory' AND entity_id = ?",
        [savedInstruction.instruction.id],
      );
      assert.equal(syncEvent?.count, 1);

      const observations = toolJson(await client.callTool({
        name: "get_daju_observations", arguments: {},
      }));
      assert.equal(observations.returnedCount, 1);
      assert.equal(observations.observations[0].perspective, "daju");

      const people = toolJson(await client.callTool({
        name: "get_people_context", arguments: {},
      }));
      assert.equal(people.people.find((person: any) => person.username === "xu").returnedCount, 1);
      assert.equal(people.people.find((person: any) => person.username === "si").returnedCount, 1);
      assert.equal(people.sharedReturnedCount, 1);
      assert.deepEqual(people.sharedFacts[0].subjects, ["both"]);
    } finally {
      await client.close();
      await server.close();
    }
  });
});
