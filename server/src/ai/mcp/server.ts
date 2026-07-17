import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { all, get, type MessageRow } from "../../db";
import { accounts } from "../accounts";
import { addMemory, searchMemory, visibleMemoryScopes } from "../memory/store";
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
      // 细则写在各 tool description；此处只保留一行总则，避免与 Agent system 重复。
      instructions:
        "工具按名选用；记忆与聊天不得越权。人物：facts→events→原话搜索。行为要求通常已在对话上下文中，勿重复 get_daju_instructions。",
    },
  );

  server.registerTool(
    "search_facts",
    {
      description: "稳定事实/喜好/身份/禁忌。近况身体用 get_current_states。人物未命中身份关系时接着 search_events，勿直接 search_chat_messages。",
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
      description: "过去经历/事件。命中即用；仅要逐字原话时再 search_chat_messages。",
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
      description: "主人原话检索（不含大橘回复）。人物须先 facts+events。query 用核心概念，可用 alternatives。",
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
      description: "展开某条聊天前后文，确认代词/否定/玩笑含义。",
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
      description: "聊天提取的计划/承诺。validUntil=卡片有效期非执行截止；正式提醒用 list_personal_items。",
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
      description: "分人物返回核心事实卡；仅需长期背景时调用。",
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
      description: "近几天近况（身体/忙碌/情绪等）；每主体最新一张。",
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
      description: "近期关系滚动总结；非长期约定、非单次裁决。",
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
      description: "互动方式理解卡；仅分析/复盘/调解时用，表述须谨慎。",
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
    "save_daju_instruction",
    {
      description: "保存长期大橘行为要求。topic 稳定复用；临时格式/玩笑/推断不存。",
      inputSchema: z.object({
        topic: z.string().trim().min(2).max(80).describe("稳定的简短语义主题；同一类要求更新时复用同一主题"),
        instruction: z.string().trim().min(3).max(600).describe("脱离当前对话也能独立理解的明确行为要求"),
        appliesTo: z.enum(["current_user", "both"]).optional()
          .describe("默认只表示当前主人的要求；只有主人明确说对两个人都适用时才用 both"),
      }),
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "save_daju_instruction", args, async () => {
      if (!run.identity.allowDajuInstructionWrite) {
        throw new Error("后台候选不能修改大橘指令");
      }
      if (!["couple", `ai:${run.identity.requesterUsername}`].includes(run.identity.storedChannel)) {
        throw new Error("当前聊天不能保存大橘指令");
      }
      const actor = await get<{ id: string }>(
        "SELECT id FROM accounts WHERE username = ? AND status = 'active'",
        [run.identity.requesterUsername],
      );
      if (!actor) throw new Error("当前主人身份不可用");
      const subjects = args.appliesTo === "both" ? ["both"] : [run.identity.requesterUsername];
      const item = await addMemory({
        layer: "fact",
        perspective: "daju",
        kind: "instruction",
        scope: run.identity.storedChannel,
        memoryKey: args.topic,
        subjects,
        speakers: [run.identity.requesterUsername],
        content: args.instruction,
        category: "大橘行为要求",
        confidence: 1,
        importance: 5,
        validFrom: Date.now(),
        validUntil: null,
        metadata: {
          savedDirectlyByAgent: true,
          requestedBy: run.identity.requesterUsername,
        },
      }, { actorAccountId: actor.id, restoreExcluded: true });
      if (!item) throw new Error("大橘指令保存失败");
      return {
        saved: true,
        updatedExistingTopic: Boolean(item.supersedesId),
        instruction: memoryView(item),
      };
    })),
  );

  server.registerTool(
    "get_daju_instructions",
    {
      description: "仅当用户消息中没有【大橘当前行为要求】块时使用；通常已预置，勿重复调用。",
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
