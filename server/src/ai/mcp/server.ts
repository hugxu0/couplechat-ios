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

function resolveSubject(value: string | undefined): string | undefined {
  if (!value) return undefined;
  return accounts().find((account) => account.username === value || account.name === value)?.username ?? value;
}

function memoryResult(key: string, rows: Awaited<ReturnType<typeof searchMemory>>) {
  return {
    source: "memory",
    hasRelevantCandidates: rows.length > 0,
    returnedCount: rows.length,
    [key]: rows.map(memoryView),
  };
}

export function createCoupleChatMcpServer(run: AgentToolRun): McpServer {
  const server = new McpServer(
    { name: "couplechat-ai-tools", version: "0.1.0" },
    {
      instructions:
        "按问题类型选择结构化记忆：事实 search_facts、经历 search_events、计划 search_plans、近况 get_current_states、近期关系 get_relationship_context、互动理解 get_current_insight；涉及大橘行为规则时读取 get_daju_instructions，涉及大橘观察或复盘时读取 get_daju_observations。人物查询按 search_facts → search_events → search_chat_messages 回退，facts 为空时不能跳过 events。结构化记忆命中后直接使用；只有用户明确要求逐字原话，或 facts/events 都为空时，才搜索原始聊天。任何记忆都不能跨越当前频道权限。",
    },
  );

  server.registerTool(
    "search_facts",
    {
      description: "搜索稳定事实、喜好、习惯、身份、重要人物以及长期健康禁忌。临时生病或近期身体状态应调用 get_current_states。人物查询没有命中或没有回答身份/关系时，下一步必须用同一个名字调用 search_events，不能直接跳到 search_chat_messages。",
      inputSchema: z.object({
        query: z.string().min(1).max(300),
        subject: z.string().max(40).optional().describe("username、主人昵称、both 或留空"),
        limit: z.number().int().min(1).max(8).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "search_facts", args, async () => {
      const wantedSubject = resolveSubject(args.subject);
      const rows = await searchMemory({
        query: args.query,
        layers: ["fact"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        subjects: wantedSubject ? [wantedSubject] : undefined,
        limit: safeLimit(args.limit, 5, 8),
      });
      return {
        query: args.query,
        subject: wantedSubject ?? null,
        ...memoryResult("facts", rows),
      };
    })));

  server.registerTool(
    "search_events",
    {
      description: "搜索过去发生的经历和事件事实，适合‘上次、前几天、什么时候、后来怎样’。命中后直接使用，不要继续搜索聊天；只有用户明确要求逐字原话时才调用 search_chat_messages。",
      inputSchema: z.object({
        query: z.string().min(1).max(300),
        subject: z.string().max(40).optional().describe("username、主人昵称、both 或留空"),
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
      const wantedSubject = resolveSubject(args.subject);
      const rows = await searchMemory({
        query: args.query,
        layers: ["event"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        subjects: wantedSubject ? [wantedSubject] : undefined,
        from: from ?? undefined,
        to: to ?? undefined,
        limit: safeLimit(args.limit, 6, 10),
      });
      return {
        query: args.query,
        subject: wantedSubject ?? null,
        ...memoryResult("events", rows),
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
      description: "搜索从聊天提取出的当前计划、承诺和安排，可按人物筛选。返回的 memoryValidUntil 是卡片继续有效的时间，不是计划的执行时间或截止时间；正式提醒/备忘仍以 list_personal_items 为准。",
      inputSchema: z.object({
        query: z.string().min(1).max(300),
        subject: z.string().max(40).optional().describe("username、主人昵称、both 或留空"),
        limit: z.number().int().min(1).max(10).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "search_plans", args, async () => {
      const wantedSubject = resolveSubject(args.subject);
      const rows = await searchMemory({
        query: args.query,
        layers: ["plan"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        subjects: wantedSubject ? [wantedSubject] : undefined,
        limit: safeLimit(args.limit, 6, 10),
      });
      return { query: args.query, subject: wantedSubject ?? null, ...memoryResult("plans", rows) };
    })));

  server.registerTool(
    "get_people_context",
    {
      description: "读取两位主人的核心人物事实，并把小旭、小偲和两个人共同的事实分开返回。只在理解人物身份和长期背景确实需要时调用。",
      inputSchema: z.object({}),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_people_context", args, async () => {
      const visibleAccounts = accounts();
      const scopes = visibleMemoryScopes(run.identity.storedChannel);
      const [peopleFacts, sharedFacts] = await Promise.all([
        Promise.all(visibleAccounts.map((account) => searchMemory({
          query: "",
          layers: ["fact"],
          scopes,
          subjects: [account.username],
          subjectMode: "exact",
          sort: "importance",
          limit: 12,
        }))),
        searchMemory({
          query: "",
          layers: ["fact"],
          scopes,
          subjects: ["both"],
          subjectMode: "exact",
          sort: "importance",
          limit: 12,
        }),
      ]);
      return {
        source: "memory",
        people: visibleAccounts.map((account, index) => ({
          username: account.username,
          name: account.name,
          returnedCount: peopleFacts[index].length,
          facts: peopleFacts[index].map(memoryView),
        })),
        sharedFacts: sharedFacts.map(memoryView),
        sharedReturnedCount: sharedFacts.length,
      };
    })));

  server.registerTool(
    "get_current_states",
    {
      description: "读取最近几天的滚动近况，例如生病、忙碌、活动、情绪和双方近期讨论。可按人物筛选；每个主体只返回最新一张当前卡。",
      inputSchema: z.object({
        subject: z.string().max(40).optional().describe("username、主人昵称、both 或留空"),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_current_states", args, async () => {
      const wantedSubject = resolveSubject(args.subject);
      const rows = await searchMemory({
        query: "",
        layers: ["state"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        subjects: wantedSubject ? [wantedSubject] : undefined,
        sort: "recent",
        limit: 20,
      });
      const latestBySubject = new Map<string, typeof rows[number]>();
      for (const row of rows) {
        const subject = row.subjects[0] ?? "both";
        if (!latestBySubject.has(subject)) latestBySubject.set(subject, row);
      }
      const states = [...latestBySubject.values()];
      return { subject: wantedSubject ?? null, ...memoryResult("states", states) };
    })));

  server.registerTool(
    "get_relationship_context",
    {
      description: "读取两位主人最新的近期关系滚动总结，包括亲密、疏离、争执原因和见面后的变化。它不是长期约定清单，也不是对某一次争执的裁决。",
      inputSchema: z.object({}),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_relationship_context", args, async () => {
      const rows = await searchMemory({
        query: "",
        layers: ["relationship"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        sort: "recent",
        limit: 1,
      });
      return memoryResult("relationships", rows);
    })));

  server.registerTool(
    "get_current_insight",
    {
      description: "读取大橘当前的互动方式理解。仅在用户要求分析、复盘或调解时使用；它是根据多张基础记忆生成的滚动假设，可能出错，必须以谨慎语气表达。",
      inputSchema: z.object({}),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_current_insight", args, async () => {
      const rows = await searchMemory({
        query: "",
        layers: ["insight"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        sort: "recent",
        limit: 1,
      });
      return {
        warning: "这是观察性假设，不是确定事实",
        ...memoryResult("insights", rows),
      };
    })));

  server.registerTool(
    "get_daju_instructions",
    {
      description: "读取主人明确交给大橘的行为要求和偏好。它们是大橘的动态行为约束，当前主人消息和系统安全规则优先级更高。",
      inputSchema: z.object({}),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_daju_instructions", args, async () => {
      const rows = await searchMemory({
        query: "",
        layers: ["fact"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        perspectives: ["daju"],
        kinds: ["instruction"],
        sort: "importance",
        limit: 20,
      });
      return {
        warning: "这些是主人明确提出的动态要求；当前请求和系统规则优先",
        ...memoryResult("instructions", rows),
      };
    })));

  server.registerTool(
    "get_daju_observations",
    {
      description: "读取大橘根据多条主人记忆形成的观察性假设。仅用于相关的复盘、理解和调解，不能当作确定事实。",
      inputSchema: z.object({
        query: z.string().max(300).optional(),
        subject: z.string().max(40).optional().describe("username、主人昵称、both 或留空"),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "get_daju_observations", args, async () => {
      const wantedSubject = resolveSubject(args.subject);
      const rows = await searchMemory({
        query: args.query ?? "",
        layers: ["insight"],
        scopes: visibleMemoryScopes(run.identity.storedChannel),
        perspectives: ["daju"],
        kinds: ["observation"],
        subjects: wantedSubject ? [wantedSubject] : undefined,
        sort: args.query?.trim() ? "relevance" : "recent",
        limit: 8,
      });
      return {
        warning: "这是大橘的观察性假设，可能不准确，不能当作主人明确说过的事实",
        subject: wantedSubject ?? null,
        ...memoryResult("observations", rows),
      };
    })));

  registerPersonalItemTools(server, run);
  registerExternalTools(server, run);

  return server;
}
