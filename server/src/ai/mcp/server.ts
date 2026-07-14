import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { all, get, type MessageRow } from "../../db";
import { accounts } from "../accounts";
import { searchMemory, visibleMemoryScopes } from "../memory/store";
import { recordAgentTool, type AgentToolRun } from "./runContext";
import { rankChatSearchRows, searchTerms, type ChatSearchMode } from "../conversation/search";
import { registerExternalTools } from "./externalTools";
import { registerPersonalItemTools } from "./personalItemTools";
import { allowedChannels, jsonResult, memoryView, messageView, parseTime, safeLimit } from "./toolSupport";

export function createCoupleChatMcpServer(run: AgentToolRun): McpServer {
  const server = new McpServer(
    { name: "couplechat-ai-tools", version: "0.1.0" },
    {
      instructions:
        "先用结构化事实/事件工具。人物查询按 search_facts → search_events → search_chat_messages 回退，facts 为空时不能跳过 events。结构化记忆命中后直接使用；只有用户明确要求逐字原话，或 facts/events 都为空时，才搜索原始聊天。任何记忆都不能跨越当前频道权限。",
    },
  );

  server.registerTool(
    "search_facts",
    {
      description: "搜索稳定事实、喜好、健康、习惯、身份和重要人物。人物查询没有命中或没有回答身份/关系时，下一步必须用同一个名字调用 search_events，不能直接跳到 search_chat_messages。",
      inputSchema: z.object({
        query: z.string().min(1).max(300),
        subject: z.string().max(40).optional().describe("username、主人昵称、both 或留空"),
        categories: z.array(z.string()).max(8).optional(),
        limit: z.number().int().min(1).max(8).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "search_facts", args, async () => {
      const wantedSubject = args.subject
        ? accounts().find((a) => a.username === args.subject || a.name === args.subject)?.username ?? args.subject
        : "";
      const categories = new Set(args.categories ?? []);
      const rows = (await searchMemory({
        query: args.query,
        layers: ["fact"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        subjects: wantedSubject ? [wantedSubject] : undefined,
        limit: 20,
      }))
        .filter((item) => categories.size === 0 || categories.has(item.category))
        .slice(0, safeLimit(args.limit, 5, 8));
      return {
        query: args.query,
        hasRelevantCandidates: rows.length > 0,
        source: "memory",
        facts: rows.map(memoryView),
      };
    })));

  server.registerTool(
    "search_events",
    {
      description: "搜索过去发生的经历和事件事实，适合‘上次、前几天、什么时候、后来怎样’。命中后直接使用，不要继续搜索聊天；只有用户明确要求逐字原话时才调用 search_chat_messages。",
      inputSchema: z.object({
        query: z.string().min(1).max(300),
        fromDate: z.string().max(30).optional().describe("YYYY-MM-DD"),
        toDate: z.string().max(30).optional().describe("YYYY-MM-DD"),
        limit: z.number().int().min(1).max(10).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "search_events", args, async () => {
      const from = parseTime(args.fromDate);
      const toBase = parseTime(args.toDate);
      const to = toBase && /^\d{4}-\d{2}-\d{2}$/.test(args.toDate ?? "") ? toBase + 24 * 60 * 60 * 1000 - 1 : toBase;
      const rows = await searchMemory({
        query: args.query,
        layers: ["event"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        from: from ?? undefined,
        to: to ?? undefined,
        limit: safeLimit(args.limit, 6, 10),
      });
      return {
        query: args.query,
        hasRelevantCandidates: rows.length > 0,
        source: "memory",
        events: rows.map(memoryView),
      };
    })));

  server.registerTool(
    "search_chat_messages",
    {
      description: "搜索两位主人的原始聊天证据，不返回大橘自己的旧回答。人物身份/关系查询必须先尝试 search_facts 和 search_events；只有两者都为空或用户明确要求逐字原话时才使用本工具。query 填核心概念；需要发散时由你在 alternatives 中给出少量不同表达。",
      inputSchema: z.object({
        query: z.string().min(1).max(240),
        alternatives: z.array(z.string().min(1).max(120)).max(5).optional().describe("由 Agent 根据当前问题生成的不同表达，不要重复原查询"),
        match: z.enum(["hybrid", "all", "any"]).optional().describe("默认 hybrid；all 仅优先尝试同一条消息全命中，失败会自动放宽"),
        sender: z.string().max(40).optional().describe("username 或主人昵称"),
        from: z.string().max(40).optional().describe("ISO 时间、日期或毫秒时间戳"),
        to: z.string().max(40).optional().describe("ISO 时间、日期或毫秒时间戳"),
        limit: z.number().int().min(1).max(12).optional(),
        includeContext: z.boolean().optional().describe("默认展开前后各 2 条消息，帮助找到分散在相邻消息里的日期和答案"),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "search_chat_messages", args, async () => {
      const channels = allowedChannels(run);
      const queries = [args.query, ...(args.alternatives ?? [])];
      const tokens = searchTerms(queries.join(" "));
      if (!tokens.length) {
        return {
          query: args.query,
          match: args.match ?? "hybrid",
          effectiveMatch: args.match ?? "hybrid",
          relaxed: false,
          terms: [],
          alternatives: args.alternatives ?? [],
          hasMatches: false,
          needsMoreSpecificQuery: true,
          messages: [],
        };
      }
      const clauses = [
        `channel IN (${channels.map(() => "?").join(",")})`,
        "kind = 'user'",
        "type = 'text'",
        "sender <> 'ai'",
      ];
      const params: Array<string | number> = [...channels];
      if (run.identity.messageId) {
        clauses.push("id <> ?");
        params.push(run.identity.messageId);
      }
      // SQL 只负责候选召回，匹配模式和相关性由统一重排器处理。
      clauses.push(`(${tokens.map(() => "text ILIKE ?").join(" OR ")})`);
      params.push(...tokens.map((token) => `%${token}%`));
      if (args.sender) {
        const sender = accounts().find((a) => a.username === args.sender || a.name === args.sender)?.username ?? args.sender;
        clauses.push("sender = ?");
        params.push(sender);
      }
      const from = parseTime(args.from);
      const to = parseTime(args.to);
      if (from) { clauses.push("ts >= ?"); params.push(from); }
      if (to) { clauses.push("ts <= ?"); params.push(to); }
      // 多取候选，避免最近的高频词命中挤掉较早的稀有证据。
      params.push(Math.min(1000, Math.max(120, safeLimit(args.limit, 8, 12) * 24)));
      const rows = await all<MessageRow>(
        `SELECT * FROM messages WHERE ${clauses.join(" AND ")} ORDER BY ts DESC LIMIT ?`,
        params,
      );
      const ranked = rankChatSearchRows(rows, queries, (args.match ?? "hybrid") as ChatSearchMode, safeLimit(args.limit, 8, 12));
      const context = args.includeContext === false ? [] : await Promise.all(ranked.hits.slice(0, 3).map(async (hit) => {
        const anchor = hit.row;
        const beforeClauses = ["channel = ?", "(ts < ? OR (ts = ? AND id < ?))"];
        const afterClauses = ["channel = ?", "(ts > ? OR (ts = ? AND id > ?))"];
        const beforeParams: Array<string | number> = [anchor.channel, anchor.ts, anchor.ts, anchor.id];
        const afterParams: Array<string | number> = [anchor.channel, anchor.ts, anchor.ts, anchor.id];
        if (run.identity.messageId) {
          beforeClauses.push("id <> ?");
          afterClauses.push("id <> ?");
          beforeParams.push(run.identity.messageId);
          afterParams.push(run.identity.messageId);
        }
        const before = await all<MessageRow>(
          `SELECT * FROM messages WHERE ${beforeClauses.join(" AND ")} ORDER BY ts DESC, id DESC LIMIT 2`,
          beforeParams,
        );
        const after = await all<MessageRow>(
          `SELECT * FROM messages WHERE ${afterClauses.join(" AND ")} ORDER BY ts ASC, id ASC LIMIT 2`,
          afterParams,
        );
        return {
          anchorId: anchor.id,
          messages: [...before.reverse(), anchor, ...after].map((row) => messageView(row)),
        };
      }));
      return {
        query: args.query,
        match: args.match ?? "hybrid",
        effectiveMatch: ranked.effectiveMode,
        relaxed: ranked.relaxed,
        terms: ranked.terms,
        alternatives: args.alternatives ?? [],
        hasMatches: ranked.hits.length > 0,
        messages: ranked.hits.map((hit) => messageView(hit.row, {
          matchedTerms: hit.matchedTerms,
          relevance: hit.relevance,
        })),
        context,
      };
    })));

  server.registerTool(
    "get_messages_around",
    {
      description: "展开某条原始聊天消息前后的上下文，用于确认代词、说话人、否定、玩笑以及事件真实含义。",
      inputSchema: z.object({
        messageId: z.string().min(1).max(100),
        before: z.number().int().min(1).max(15).optional(),
        after: z.number().int().min(1).max(15).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_messages_around", args, async () => {
      const anchor = await get<MessageRow>("SELECT * FROM messages WHERE id = ?", [args.messageId]);
      if (!anchor || !allowedChannels(run).includes(anchor.channel)) return { found: false };
      const before = await all<MessageRow>(
        `SELECT * FROM messages
         WHERE channel = ? AND (ts < ? OR (ts = ? AND id < ?))
         ORDER BY ts DESC, id DESC LIMIT ?`,
        [anchor.channel, anchor.ts, anchor.ts, anchor.id, safeLimit(args.before, 5, 15)],
      );
      const after = await all<MessageRow>(
        `SELECT * FROM messages
         WHERE channel = ? AND (ts > ? OR (ts = ? AND id > ?))
         ORDER BY ts ASC, id ASC LIMIT ?`,
        [anchor.channel, anchor.ts, anchor.ts, anchor.id, safeLimit(args.after, 5, 15)],
      );
      return { found: true, messages: [...before.reverse(), anchor, ...after].map((row) => messageView(row)) };
    })));

  server.registerTool(
    "search_plans",
    {
      description: "搜索从聊天提取出的未来计划、承诺和安排。正式提醒/备忘仍以 list_personal_items 为准。",
      inputSchema: z.object({
        query: z.string().min(1).max(300),
        limit: z.number().int().min(1).max(10).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "search_plans", args, async () => ({
      source: "memory",
      plans: (await searchMemory({
        query: args.query,
        layers: ["plan"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        limit: safeLimit(args.limit, 6, 10),
      })).map(memoryView),
    }))));

  server.registerTool(
    "get_people_context",
    {
      description: "读取人物档案卡。只在理解人物身份和长期背景确实需要时调用。",
      inputSchema: z.object({}),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_people_context", args, async () => {
      const visibleAccounts = run.identity.storedChannel === "couple" ? accounts() : accounts();
      const facts = await searchMemory({
        query: "",
        layers: ["fact"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        subjects: visibleAccounts.map((account) => account.username),
        limit: 20,
      });
      return {
        source: "memory",
        people: visibleAccounts.map((account) => ({
          username: account.username,
          name: account.name,
          facts: facts.filter((fact) => fact.subjects.includes(account.username)).map(memoryView),
        })),
      };
    })));

  server.registerTool(
    "get_current_states",
    {
      description: "读取当前短期状态和今日心情，例如最近生病、忙碌、旅行或近期整体背景。这些是会变化的状态，不是永久事实。",
      inputSchema: z.object({}),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_current_states", args, async () => ({
      source: "memory",
      states: (await searchMemory({
        query: "",
        layers: ["state"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        limit: 12,
      })).map(memoryView),
    }))));

  server.registerTool(
    "get_relationship_context",
    {
      description: "读取两位主人共同的关系卡和明确关系约定。它是长期背景，不是对某一次争执的裁决。",
      inputSchema: z.object({}),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_relationship_context", args, async () => ({
      source: "memory",
      relationships: (await searchMemory({
        query: "",
        layers: ["relationship"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        limit: 12,
      })).map(memoryView),
    }))));

  server.registerTool(
    "search_insights",
    {
      description: "搜索大橘过去形成的观察或关系模式。仅在用户要求分析、复盘或调解时使用；结果是可能出错的假设，必须以谨慎语气表达。",
      inputSchema: z.object({
        query: z.string().min(1).max(300),
        limit: z.number().int().min(1).max(10).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "search_insights", args, async () => {
      const insights = await searchMemory({
        query: args.query,
        layers: ["insight"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        limit: safeLimit(args.limit, 5, 10),
      });
      return { source: "memory", warning: "这些是观察性假设，不是确定事实", insights: insights.map(memoryView) };
    })));

  registerPersonalItemTools(server, run);
  registerExternalTools(server, run);

  return server;
}
