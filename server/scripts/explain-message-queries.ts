import assert from "node:assert/strict";
import { withTestDatabase } from "../tests/support/postgresHarness";

interface ExplainRoot {
  Plan: PlanNode;
  "Planning Time": number;
  "Execution Time": number;
}

interface PlanNode {
  "Node Type": string;
  "Index Name"?: string;
  Plans?: PlanNode[];
}

function summarizePlan(plan: PlanNode): { nodes: string[]; indexes: string[] } {
  const children = plan.Plans?.map(summarizePlan) ?? [];
  return {
    nodes: [plan["Node Type"], ...children.flatMap((child) => child.nodes)],
    indexes: [plan["Index Name"], ...children.flatMap((child) => child.indexes)]
      .filter((value): value is string => Boolean(value)),
  };
}

async function main(): Promise<void> {
  await withTestDatabase(async () => {
    const db = await import("../src/db");
    const now = Date.now();
    await db.run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, ts, client_id)
       SELECT 'perf_couple_' || value,
              'couple',
              CASE WHEN value % 2 = 0 THEN 'xu' ELSE 'si' END,
              CASE WHEN value % 2 = 0 THEN '小旭' ELSE '小偲' END,
              'user', 'text',
              CASE WHEN value % 997 = 0 THEN '包含性能关键字的历史消息' ELSE '普通聊天历史消息 ' || value END,
              ?::bigint + value,
              'perf_client_' || value
         FROM generate_series(1, 50000) AS value`,
      [now - 50_000],
    );
    await db.run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, ts)
       SELECT 'perf_ai_' || value, 'ai:xu', 'xu', '小旭', 'user', 'text', 'AI 私聊历史 ' || value, ?::bigint + value
         FROM generate_series(1, 10000) AS value`,
      [now - 10_000],
    );
    await db.run("ANALYZE messages");

    const samples: Array<[string, string, unknown[]]> = [
      ["bootstrap-latest", "SELECT * FROM messages WHERE channel = ? ORDER BY ts DESC LIMIT ?", ["couple", 40]],
      ["before-page", "SELECT * FROM messages WHERE channel = ? AND ts < ? ORDER BY ts DESC LIMIT ?", ["couple", now - 10_000, 300]],
      ["around-before", "SELECT * FROM messages WHERE channel = ? AND ts < ? ORDER BY ts DESC LIMIT ?", ["couple", now - 25_000, 150]],
      ["around-after", "SELECT * FROM messages WHERE channel = ? AND ts > ? ORDER BY ts ASC LIMIT ?", ["couple", now - 25_000, 150]],
      ["search", "SELECT * FROM messages WHERE channel = ? AND text LIKE ? ORDER BY ts DESC LIMIT ?", ["couple", "%性能关键字%", 50]],
    ];

    for (const [label, sql, params] of samples) {
      const rows = await db.all<Record<string, unknown>>(
        `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${sql}`,
        params,
      );
      const value = rows[0]?.["QUERY PLAN"] as ExplainRoot[] | undefined;
      const explain = value?.[0];
      assert.ok(explain, `missing EXPLAIN result for ${label}`);
      assert.ok(explain["Execution Time"] < 100, `${label} exceeded 100ms`);
      const summary = summarizePlan(explain.Plan);
      console.log(JSON.stringify({
        query: label,
        rows: label === "search" ? 50_000 : undefined,
        nodes: summary.nodes,
        indexes: summary.indexes,
        planningMs: explain["Planning Time"],
        executionMs: explain["Execution Time"],
      }));
    }
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
