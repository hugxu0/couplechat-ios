import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { all, type PersonalItemRow } from "../../db";
import { describeAction, type AiAction } from "../actions/personalItems";
import { beijingDateTime } from "../time";
import { recordAgentTool, type AgentToolRun } from "./runContext";
import { jsonResult, safeLimit } from "./toolSupport";

export function defaultPersonalItemScope(storedChannel: string): "personal" | "shared" {
  return storedChannel === "couple" ? "shared" : "personal";
}

export function resolveDraftPersonalItemScope(
  storedChannel: string,
  requested?: "personal" | "shared",
): "personal" | "shared" {
  return requested ?? defaultPersonalItemScope(storedChannel);
}

export function registerPersonalItemTools(server: McpServer, run: AgentToolRun): void {
  server.registerTool(
    "list_personal_items",
    {
      description: "查询可见提醒/备忘；scope=personal|shared|all。",
      inputSchema: z.object({
        kind: z.enum(["reminder", "memo", "all"]).optional(),
        scope: z.enum(["personal", "shared", "all"]).optional(),
        includeDone: z.boolean().optional(),
        limit: z.number().int().min(1).max(30).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "list_personal_items", args, async () => {
      const requestedScope = args.scope ?? defaultPersonalItemScope(run.identity.storedChannel);
      const clauses: string[] = [];
      const params: Array<string | number> = [];
      if (requestedScope === "personal") {
        clauses.push("scope = 'personal' AND owner = ?");
        params.push(run.identity.requesterUsername);
      } else if (requestedScope === "shared") {
        clauses.push("scope = 'shared'");
      } else {
        clauses.push("(scope = 'shared' OR (scope = 'personal' AND owner = ?))");
        params.push(run.identity.requesterUsername);
      }
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
      description: "生成提醒/备忘增删改确认草案（不直接写入）。personal/shared 必分清；改删前先 list 取 id；memo 的 title 与 text 勿重复。",
      inputSchema: z.object({
        type: z.enum(["add_reminder", "add_memo", "complete_reminder", "edit_reminder", "delete_reminder", "edit_memo", "delete_memo"]),
        title: z.string().max(300).optional(),
        text: z.string().max(4000).optional(),
        time: z.string().max(40).optional().describe("新增提醒必须是北京时间 YYYY-MM-DD HH:mm"),
        id: z.string().max(100).optional(),
        newText: z.string().max(4000).optional(),
        newTitle: z.string().max(300).optional(),
        newTime: z.string().max(40).optional().describe("修改提醒时间时使用北京时间 YYYY-MM-DD HH:mm"),
        ownerName: z.string().max(40).optional(),
        scope: z.enum(["personal", "shared"]).optional(),
      }),
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "draft_personal_item_action", args, async () => {
      const action: AiAction = { ...args };
      action.scope = resolveDraftPersonalItemScope(run.identity.storedChannel, action.scope);
      if (action.scope === "personal") action.ownerName = run.identity.requesterUsername;
      const label = describeAction(action);
      if (!label) throw new Error("操作草案缺少必要字段");
      if (!run.actions.some((existing) => JSON.stringify(existing) === JSON.stringify(action))) run.actions.push(action);
      return { drafted: true, label, action, requiresUserConfirmation: true };
    })),
  );
}
