import { all, closeDatabase, initDatabase, run, type AiMemoryRow } from "../db";
import { chat, extractJson } from "../ai/provider";
import { GEN } from "../ai/settings";

interface ClassifiedSubject {
  id?: string;
  subject?: "xu" | "si" | "both";
  confidence?: number;
  reason?: string;
}

function numberArgument(name: string, fallback: number): number {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? Number(process.argv[index + 1]) : fallback;
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

async function main(): Promise<void> {
  const apply = process.argv.includes("--apply");
  const days = Math.min(90, numberArgument("--days", 14));
  const limit = Math.min(200, numberArgument("--limit", 60));
  const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;

  await initDatabase();
  try {
    const rows = await all<AiMemoryRow>(
      `SELECT * FROM ai_memory
       WHERE status = 'active'
         AND subjects_json::jsonb = '["both"]'::jsonb
         AND (
           layer IN ('fact','plan','state')
           OR (
             layer = 'event'
             AND COALESCE(occurred_at, created_at) >= ?
             AND COALESCE(metadata_json::jsonb ->> 'legacyReviewed', 'false') = 'true'
           )
         )
       ORDER BY CASE WHEN layer = 'event' THEN 1 ELSE 0 END,
                COALESCE(occurred_at, created_at) DESC LIMIT ?`,
      [cutoff, limit],
    );
    if (!rows.length) {
      console.info("没有需要复核的人物归属卡片。");
      return;
    }

    const output = await chat({
      profile: "task",
      system: [
        "你在复核 CoupleChat 的事实、经历、计划和近况卡人物归属。只判断内容实际属于谁，不按可见范围、说话人或是否被两人讨论来判断。",
        "subject=xu：事情主体只有小旭；subject=si：事情主体只有小偲；subject=both：两个人共同参与、共同执行或事件本身描述两人的共同经历。",
        "不确定时保持 both。不要改写内容。",
        '只输出 JSON：{"items":[{"id":"mem_x","subject":"xu","confidence":0.9,"reason":"事件主体是小旭"}]}',
      ].join("\n"),
      user: rows.map((row) => `[${row.id}] layer=${row.layer} ${row.content}`).join("\n"),
      gen: GEN.extractFacts,
    });
    const parsed = extractJson<{ items?: ClassifiedSubject[] }>(output);
    if (!parsed?.items) throw new Error("人物归属复核 JSON 无效");
    const rowById = new Map(rows.map((row) => [row.id, row]));
    const accepted = parsed.items.filter((item) =>
      item.id && rowById.has(item.id)
      && (item.subject === "xu" || item.subject === "si" || item.subject === "both")
      && Number(item.confidence) >= 0.75);
    console.info(`候选 ${rows.length} 张（事实/计划/近况全部 + 近 ${days} 天少量旧事件）；高置信复核 ${accepted.length} 张；模式=${apply ? "写入" : "预览"}`);
    for (const item of accepted) {
      const row = rowById.get(item.id!)!;
      console.info(`${row.id} both -> ${item.subject}: ${row.content.slice(0, 90)} (${item.reason ?? ""})`);
      if (!apply || item.subject === "both") continue;
      let metadata: Record<string, unknown> = {};
      try { metadata = JSON.parse(row.metadata_json) as Record<string, unknown>; } catch { /* 保留空对象 */ }
      await run(
        `UPDATE ai_memory SET subjects_json = ?, metadata_json = ?, embedding = NULL, updated_at = ?
         WHERE id = ? AND subjects_json::jsonb = '["both"]'::jsonb`,
        [
          JSON.stringify([item.subject]),
          JSON.stringify({
            ...metadata,
            originalSubjects: ["both"],
            reclassifiedAt: Date.now(),
            reclassifier: "recent-subject-v1",
            reclassificationReason: item.reason ?? "",
          }),
          Date.now(),
          row.id,
        ],
      );
    }
  } finally {
    await closeDatabase();
  }
}

void main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
