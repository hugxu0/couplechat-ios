import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { all, type PersonalItemRow } from "../../db";
import { describeAction, type AiAction } from "../actions/personalItems";
import { beijingDateTime } from "../time";
import { recordAgentTool, type AgentToolRun } from "./runContext";
import { jsonResult, safeLimit } from "./toolSupport";

export function registerPersonalItemTools(server: McpServer, run: AgentToolRun): void {
  server.registerTool(
    "list_personal_items",
    {
      description: "查询当前可见的未完成提醒和备忘。公聊只返回 shared；AI 私聊返回 shared 和当前主人的 personal。",
      inputSchema: z.object({
        kind: z.enum(["reminder", "memo", "all"]).optional(),
        includeDone: z.boolean().optional(),
        limit: z.number().int().min(1).max(30).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "list_personal_items", args, async () => {
      const clauses = [run.identity.storedChannel === "couple" ? "scope = 'shared'" : "(scope = 'shared' OR owner = ?)"];
      const params: Array<string | number> = [];
      if (run.identity.storedChannel !== "couple") params.push(run.identity.requesterUsername);
      if (args.kind && args.kind !== "all") { clauses.push("kind = ?"); params.push(args.kind); }
      if (!args.includeDone) clauses.push("is_done = 0");
      params.push(safeLimit(args.limit, 20, 30));
      const rows = await all<PersonalItemRow>(
        `SELECT * FROM personal_items WHERE ${clauses.join(" AND ")} ORDER BY COALESCE(due_at, updated_at) ASC LIMIT ?`,
        params,
      );
      return { items: rows.map((row) => ({
        id: row.id,
        owner: row.owner,
        kind: row.kind,
        scope: row.scope,
        title: row.title.slice(0, 300),
        bodyMarkdown: row.body_markdown.slice(0, 1200),
        dueAt: row.due_at,
        dueText: row.due_at ? beijingDateTime(row.due_at) : null,
        isDone: Boolean(row.is_done),
        updatedAt: row.updated_at,
      })) };
    })),
  );

  server.registerTool(
    "draft_personal_item_action",
    {
      description: "生成需要主人确认的提醒/备忘操作草案，不会直接写数据库。新增、完成、删除提醒或新增、修改备忘时调用。",
      inputSchema: z.object({
        type: z.enum(["add_reminder", "add_memo", "complete_reminder", "delete_reminder", "edit_memo"]),
        title: z.string().max(300).optional(),
        text: z.string().max(4000).optional(),
        time: z.string().max(40).optional().describe("新增提醒必须是北京时间 YYYY-MM-DD HH:mm"),
        id: z.string().max(100).optional(),
        newText: z.string().max(4000).optional(),
        ownerName: z.string().max(40).optional(),
        scope: z.enum(["personal", "shared"]).optional(),
      }),
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "draft_personal_item_action", args, async () => {
      const action: AiAction = { ...args };
      if (action.scope === "personal") action.ownerName = run.identity.requesterUsername;
      const label = describeAction(action);
      if (!label) throw new Error("操作草案缺少必要字段");
      if (!run.actions.some((existing) => JSON.stringify(existing) === JSON.stringify(action))) run.actions.push(action);
      return { drafted: true, label, action, requiresUserConfirmation: true };
    })),
  );
}
