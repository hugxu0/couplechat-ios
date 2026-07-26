// PostgreSQL 日常冒烟测试：启动临时数据库，建表并跑代表性业务读写路径。
// 用法（server/ 下）：npx tsx scripts/smoke-postgres.ts

import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import EmbeddedPostgres from "embedded-postgres";
import type { Server } from "socket.io";
import type { ConfirmMeta } from "../src/ai/actions/personalItems";

const PORT = 5544;
const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "couplechat-pg-"));

async function main() {
  let failureCount = 0;
  const pg = new EmbeddedPostgres({
    databaseDir: dataDir,
    user: "couplechat",
    password: "couplechat",
    port: PORT,
    persistent: false,
  });

  console.log("[1/5] 初始化内嵌 PostgreSQL…");
  await pg.initialise();
  await pg.start();
  await pg.createDatabase("couplechat");

  process.env.DATABASE_URL = `postgres://couplechat:couplechat@localhost:${PORT}/couplechat`;
  process.env.TOKEN_SECRET = "smoke-test-token-secret-not-for-production";
    process.env.PUBLIC_BASE_URL = "http://127.0.0.1:8080";
    process.env.DATA_DIR = dataDir;
    process.env.UPLOAD_DIR = dataDir;
    process.env.DATABASE_CONNECTION_TIMEOUT_MS = "5000";
    process.env.DATABASE_STATEMENT_TIMEOUT_MS = "30000";
    process.env.DATABASE_QUERY_TIMEOUT_MS = "35000";
    process.env.DATABASE_LOCK_TIMEOUT_MS = "5000";
    process.env.DATABASE_IDLE_TRANSACTION_TIMEOUT_MS = "30000";
    process.env.EMBEDDING_DIM = "1024";
    // 冒烟必须完全离线；即使开发机 .env 配了真实模型或向量服务，也不能出站。
    for (const key of [
      "AI_API_KEY",
      "AI_CHAT_API_KEY",
      "AI_TASK_API_KEY",
      "EMBEDDING_API_KEY",
      "EMBEDDING_VOYAGE_API_KEYS",
      "EMBEDDING_MONGODB_API_KEYS",
    ]) {
      process.env[key] = "";
    }

  let closeDatabase: (() => Promise<void>) | undefined;
  try {
    // 动态 import：确保 config 读到上面设置的 DATABASE_URL
    const db = await import("../src/db");
    closeDatabase = db.closeDatabase;
    console.log("[2/5] 建表…");
    await db.initDatabase(33);

    console.log("[3/5] 写入测试夹具…");
    const now = Date.now();
    await db.run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES (?, ?, ?, ?, '', 'active', 0, ?, ?), (?, ?, ?, ?, '', 'active', 0, ?, ?)`,
      [
        "acc_legacy_xu", "xu", "小旭", "smoke-hash", now, now,
        "acc_legacy_si", "si", "小偲", "smoke-hash", now, now,
      ],
    );
    const { ensureFixedCouple, ensureFixedConversations } = await import("../src/auth/accounts");
    await ensureFixedCouple();
    await ensureFixedConversations();
    for (let index = 0; index < 120; index += 1) {
      const sender = index % 2 === 0 ? "xu" : "si";
      await db.run(
        `INSERT INTO messages
         (id, channel, sender, sender_name, kind, type, text, ts, conversation_id, sender_account_id)
         VALUES (?, 'couple', ?, ?, 'user', 'text', ?, ?, 'conv_legacy_couple', ?)`,
        [
          `smoke-source-${index}`,
          sender,
          sender === "xu" ? "小旭" : "小偲",
          index % 7 === 0 ? `第 ${index} 条喵消息` : `第 ${index} 条测试消息`,
          now - (120 - index) * 60_000,
          `acc_legacy_${sender}`,
        ],
      );
    }

    console.log("[4/5] 服务层冒烟…");
    const assertOk = (label: string, cond: boolean) => {
      console.log(`  ${cond ? "✓" : "✗"} ${label}`);
      if (!cond) failureCount += 1;
    };

    await db.run("CREATE ROLE card_game_web_owner NOLOGIN");
    await db.run("ALTER TABLE accounts OWNER TO card_game_web_owner");
    await db.migrate(db.databasePool());
    const databaseTimeouts = await db.get<{
      statement_timeout: string;
      lock_timeout: string;
      idle_transaction_timeout: string;
    }>(
      `SELECT current_setting('statement_timeout') AS statement_timeout,
              current_setting('lock_timeout') AS lock_timeout,
              current_setting('idle_in_transaction_session_timeout') AS idle_transaction_timeout`,
    );
    assertOk(
      "应用连接池限制连接、查询、锁等待和空闲事务时长",
      db.databasePool().options.connectionTimeoutMillis === 5_000 &&
        db.databasePool().options.query_timeout === 35_000 &&
        databaseTimeouts?.statement_timeout === "30s" &&
        databaseTimeouts.lock_timeout === "5s" &&
        databaseTimeouts.idle_transaction_timeout === "30s",
    );
    const cardTableOwners = await db.all<{ table_name: string; owner_name: string }>(
      `SELECT table_info.relname AS table_name,
              pg_get_userbyid(table_info.relowner) AS owner_name
         FROM pg_class table_info
         JOIN pg_namespace schema_info ON schema_info.oid = table_info.relnamespace
        WHERE schema_info.nspname = 'public'
          AND table_info.relname = ANY(?::text[])
        ORDER BY table_info.relname`,
      [[
        "card_game_daily_draws",
        "card_game_draws",
        "card_game_inventory",
        "card_game_effects",
      ]],
    );
    assertOk(
      "独立 migrator 创建卡牌表后会恢复 Web 表属主",
      cardTableOwners.length === 4 &&
        cardTableOwners.every((table) => table.owner_name === "card_game_web_owner"),
    );

    const migrations = await db.all<{ version: number; name: string }>(
      "SELECT version, name FROM schema_migrations ORDER BY version ASC",
    );
    const expectedMigrations = [
      [1, "initial_schema"],
      [2, "bind_uploads_to_messages"],
      [3, "classify_upload_purpose"],
      [4, "preserve_recalled_text"],
      [5, "message_attachments"],
      [6, "memory_v2"],
      [7, "canonical_memory_names"],
      [8, "ensure_ai_runtime_state"],
      [9, "memory_import_staging"],
      [10, "memory_cursor_tie_breaker"],
      [11, "hard_delete_recalled_messages"],
      [12, "durable_reminder_bark_delivery"],
      [13, "identity_v2_expand"],
      [14, "devices_sessions_push"],
      [15, "reminder_delivery_per_endpoint"],
      [16, "conversations_and_ownership"],
      [17, "sync_v2_core"],
      [18, "tenant_memory_and_settings"],
      [19, "voice_transcription"],
      [20, "shared_albums"],
      [21, "shared_calendar"],
      [22, "shared_pet"],
      [23, "pet_care_state"],
      [24, "remove_public_registration_invites"],
      [25, "album_timeline_posts"],
      [26, "memory_derivation_dependencies"],
      [27, "retire_memory_message_evidence"],
      [28, "enforce_single_active_rolling_memory"],
      [29, "daily_recommendations"],
      [30, "daju_memory_perspective"],
      [31, "recommendation_open_category"],
      [32, "ai_daily_diaries"],
      [33, "couple_card_game"],
      [34, "repair_card_game_table_ownership"],
      [35, "scope_message_idempotency_to_device"],
      [36, "durable_ai_reply_jobs"],
    ] as const;
    assertOk(
      "数据库结构版本完整",
      migrations.length === expectedMigrations.length &&
        migrations.every((migration, index) =>
          migration.version === expectedMigrations[index][0] && migration.name === expectedMigrations[index][1]),
    );
    const latestSchemaVersion = migrations.at(-1)?.version ?? 0;
    const backupPolicy = fs.readFileSync(
      path.resolve("scripts", "backup-table-policy.sh"),
      "utf8",
    );
    const backupPolicyMaxSchema = Number(
      backupPolicy.match(/^readonly BACKUP_TABLE_POLICY_MAX_SCHEMA=(\d+)$/m)?.[1] ?? 0,
    );
    const backupTableRules = [...backupPolicy.matchAll(
      /^\s*'([a-z][a-z0-9_]*)\|([1-9][0-9]*)\|(0|[1-9][0-9]*)'\s*$/gm,
    )].map((match) => ({
      table: match[1],
      minSchema: Number(match[2]),
      maxSchema: Number(match[3]),
    }));
    const backupTables = backupTableRules
      .filter((rule) =>
        latestSchemaVersion >= rule.minSchema &&
        (rule.maxSchema === 0 || latestSchemaVersion <= rule.maxSchema))
      .map((rule) => rule.table)
      .sort();
    const publicTables = (await db.all<{ table_name: string }>(
      `SELECT table_name FROM information_schema.tables
       WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
       ORDER BY table_name`,
    )).map((row) => row.table_name).sort();
    assertOk(
      "备份策略覆盖当前 schema 的全部持久化表",
      backupPolicyMaxSchema === latestSchemaVersion &&
        backupTables.length === new Set(backupTables).size &&
        backupTables.join(",") === publicTables.join(","),
    );

    const { buildDiaryFallback, isUsableDiaryBody, normalizeDiaryBody } = await import("../src/ai/diary/service");
    const diaryFallback = buildDiaryFallback({
      moodLine: "两个人从忙乱慢慢聊到安心",
      topics: [{
        title: "周末去公园走走",
        points: ["商量了想带的零食，也记得看天气"],
      }],
    });
    assertOk(
      "大橘日记兜底保留事实并形成可读段落",
      diaryFallback.title.length > 0 &&
        diaryFallback.body.includes("周末去公园走走") &&
        diaryFallback.body.includes("\n\n") &&
        diaryFallback.body.includes("我趴在聊天旁边") &&
        !diaryFallback.body.startsWith("情绪："),
    );
    assertOk(
      "大橘日记单段模型输出会按完整句子整理",
      normalizeDiaryBody(
        "第一件小事被认真地记住了，那些细节也留在了今天的纸页上。" +
        "第二件小事同样得到了回应，两个人慢慢把没有说完的话说完整。" +
        "最后，大橘把这一天轻轻收好，等以后再回来看看它长成了什么模样。",
      )
        .includes("\n\n"),
    );
    const expandedDiaryBody = normalizeDiaryBody(
      Array.from({ length: 14 }, (_, index) =>
        `这是大橘围绕同一件事继续琢磨的第${index + 1}个完整句子，里面留下当天独有的细节和自己的想法。`,
      ).join(""),
    );
    assertOk(
      "大橘日记不会再被旧短篇上限截断",
      expandedDiaryBody.length > 520 && expandedDiaryBody.length <= 640,
    );
    assertOk(
      "大橘日记只做基础格式检查",
      isUsableDiaryBody("我趴在旁边，听见你们说起今天的一件小事，也记住了那一刻的声音和停顿。后来我在窗台上换了个姿势，继续听着你们把话慢慢说完。\n\n我有自己的小心思，也把最后那句晚安、房间里的安静和一点没有说完的尾巴一起收好了。我没有急着给这件事找答案，只想再守一会儿，看看明天醒来时，那句没说完的话会不会自己长出新的尾巴。\n\n有些话在人类嘴里很短，落到猫耳朵里却会响很久。我把爪子压在肚皮下面，忽然觉得等待也不是一件空荡荡的事，因为我还记得你们说那句话时，一个人没有躲开，另一个人也没有催促。"),
    );
    assertOk(
      "大橘日记只拒绝明显的非正文输出",
      !isUsableDiaryBody("根据输入的JSON生成正文"),
    );

    const legacyMembers = await db.all<{ username: string }>(
      `SELECT account.username FROM couple_members member
       JOIN accounts account ON account.id = member.account_id
       WHERE member.couple_id = 'cpl_legacy_xusi' AND member.state = 'active'
       ORDER BY account.username`,
    );
    assertOk("legacy xu/si 已无感回填为同一情侣", legacyMembers.map((item) => item.username).join(",") === "si,xu");

    const { readReceiptSchema } = await import("../src/contracts/realtime");
    const fractionalRead = readReceiptSchema.safeParse({ channel: "couple", ts: 1783653931714.444 });
    assertOk(
      "iOS 小数毫秒已读回执会归一化为 BIGINT",
      fractionalRead.success && fractionalRead.data.ts === 1783653931714,
    );
    const { sendMessageSchema } = await import("../src/contracts/realtime");
    assertOk(
      "媒体消息要求 uploadId",
      !sendMessageSchema.safeParse({ channel: "couple", type: "image", text: "[图片]" }).success,
    );
    const duplicateLivePhotoRole = sendMessageSchema.safeParse({
      channel: "couple",
      type: "image",
      text: "[实况照片]",
      attachments: [
        { assetId: "asset_smoke_live", role: "photo", uploadId: "up_smoke_live_photo_a", order: 0 },
        { assetId: "asset_smoke_live", role: "photo", uploadId: "up_smoke_live_photo_b", order: 0 },
      ],
    });
    const duplicatePairedVideoRole = sendMessageSchema.safeParse({
      channel: "couple",
      type: "image",
      text: "[实况照片]",
      attachments: [
        { assetId: "asset_smoke_live", role: "photo", uploadId: "up_smoke_live_photo_c", order: 0 },
        { assetId: "asset_smoke_live", role: "pairedVideo", uploadId: "up_smoke_live_video_a", order: 0 },
        { assetId: "asset_smoke_live", role: "pairedVideo", uploadId: "up_smoke_live_video_b", order: 0 },
      ],
    });
    assertOk(
      "Live Photo 每个 asset 恰好一张 photo 且最多一个 pairedVideo",
      !duplicateLivePhotoRole.success && !duplicatePairedVideoRole.success,
    );
    assertOk(
      "贴纸消息必须提供既有贴纸 URL",
      !sendMessageSchema.safeParse({ channel: "couple", type: "sticker", text: "[表情]" }).success,
    );
    const { loginRateLimitIp } = await import("../src/auth/routes");
    const spoofedForwardedRequest = {
      ip: "::ffff:127.0.0.1",
      headers: { "x-forwarded-for": "203.0.113.9" },
    };
    assertOk(
      "登录限流不手工解析转发头，只读取 Fastify 已归一化的 request.ip",
      loginRateLimitIp(spoofedForwardedRequest) === "127.0.0.1",
    );
    const edgeNginxConfig = fs.readFileSync(
      path.join(process.cwd(), "deploy", "nginx-japan-edge-hoo66.top.conf"),
      "utf8",
    );
    assertOk(
      "日本入口从受控 Cloudflare 头恢复真实地址并覆盖客户端转发链",
      (edgeNginxConfig.match(/proxy_set_header X-Forwarded-For \$remote_addr;/g) ?? []).length === 2 &&
        !edgeNginxConfig.includes("$proxy_add_x_forwarded_for") &&
        edgeNginxConfig.includes("set_real_ip_from 127.0.0.1;") &&
        edgeNginxConfig.includes("set_real_ip_from ::1;") &&
        edgeNginxConfig.includes("real_ip_header CF-Connecting-IP;") &&
        edgeNginxConfig.includes("real_ip_recursive off;") &&
        edgeNginxConfig.includes("hoo66.top:other"),
    );
    const voiceDurationPayload = sendMessageSchema.safeParse({
      channel: "couple",
      type: "voice",
      text: "[语音]",
      uploadId: "up_smoke_voice_meta",
      meta: { media: { durationMs: 12_345 } },
    });
    assertOk(
      "语音时长元数据限制为 1...600000 整数毫秒且不能附着到其他消息类型",
      voiceDurationPayload.success &&
        voiceDurationPayload.data.meta?.media?.durationMs === 12_345 &&
        !sendMessageSchema.safeParse({
          channel: "couple",
          type: "image",
          text: "[图片]",
          uploadId: "up_smoke_image_meta",
          meta: { media: { durationMs: 12_345 } },
        }).success &&
        !sendMessageSchema.safeParse({
          channel: "couple",
          type: "voice",
          text: "[语音]",
          uploadId: "up_smoke_voice_meta",
          meta: { media: { durationMs: 600_001 } },
        }).success,
    );
    const { questionLikelyNeedsImages, questionLooksLikeImageReaction } = await import(
      "../src/ai/imageAttachment"
    );
    assertOk(
      "问图预判：明确看图才命中；短评价可作 reaction",
      questionLikelyNeedsImages("这张图是什么") &&
        !questionLikelyNeedsImages("今天天气真好") &&
        questionLooksLikeImageReaction("好看吗") &&
        questionLooksLikeImageReaction("真可爱"),
    );
    // 复合游标：同 ts 不同 id 时 beforeId 生效（直接 SQL）；时间戳放在夹具早期，避免影响最新已读锚点。
    const cursorTs = now - 200 * 60_000;
    await db.run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, ts, conversation_id, sender_account_id)
       VALUES (?, 'couple', 'xu', '小旭', 'user', 'text', ?, ?, 'conv_legacy_couple', 'acc_legacy_xu'),
              (?, 'couple', 'si', '小偲', 'user', 'text', ?, ?, 'conv_legacy_couple', 'acc_legacy_si')`,
      [
        "smoke-cursor-a", "同毫秒A", cursorTs,
        "smoke-cursor-b", "同毫秒B", cursorTs,
      ],
    );
    const cursorPage = await db.all<{ id: string }>(
      `SELECT id FROM messages
        WHERE conversation_id = 'conv_legacy_couple'
          AND (ts < ? OR (ts = ? AND id < ?))
        ORDER BY ts DESC, id DESC LIMIT 5`,
      [cursorTs, cursorTs, "smoke-cursor-b"],
    );
    assertOk(
      "消息 (ts,id) 游标可区分同毫秒",
      cursorPage.some((row) => row.id === "smoke-cursor-a") &&
        !cursorPage.some((row) => row.id === "smoke-cursor-b"),
    );
    const { ownerConversationMessagesAround } = await import("../src/ai/conversation/log");
    const nearbyDiaryMessages = await ownerConversationMessagesAround(
      "couple",
      cursorTs,
      cursorTs - 1,
      cursorTs + 1,
      8,
    );
    assertOk(
      "大橘日记原文窗口只返回边界内主人消息并保持正序",
      nearbyDiaryMessages.map((message) => message.id).join(",") ===
        "smoke-cursor-a,smoke-cursor-b" &&
      nearbyDiaryMessages.every((message) => message.kind === "user" && message.sender !== "ai"),
    );
    const { conversationMessagesInRange } = await import("../src/ai/conversation/log");
    const fullDiaryWindow = await conversationMessagesInRange(
      "couple",
      cursorTs - 1,
      cursorTs + 1,
      20,
    );
    assertOk(
      "大橘日记可按作息日顺序读取完整公聊窗口",
      fullDiaryWindow.map((message) => message.id).join(",") === "smoke-cursor-a,smoke-cursor-b",
    );
    const {
      fallbackRecommendation,
      recommendationsAreSimilar,
    } = await import("../src/daily/recommendationService");
    const previousRecommendation = {
      category: "电影",
      content: "一起看《海街日记》吧，四姐妹的日常很适合安静看完。",
    };
    const rewrittenRecommendation = {
      category: "电影",
      content: "今晚推荐《海街日记》，在细碎日常里感受温柔的陪伴。",
    };
    const rotatedFallback = fallbackRecommendation("2026-07-17", [previousRecommendation]);
    assertOk(
      "推荐刷新会识别同一具体对象并轮换兜底",
      recommendationsAreSimilar(previousRecommendation, rewrittenRecommendation) &&
        !recommendationsAreSimilar(previousRecommendation, rotatedFallback),
    );

    // AI 可靠性：超时必须发兜底；队列过载必须保留最新请求而不是静默丢弃。
    const { ReplyQueue, runReplyTaskWithTimeout } = await import("../src/ai/agent/replyQueue");
    const aiTrigger = {
      storedChannel: "ai:smoke",
      question: "测试",
      requesterName: "测试用户",
      requesterUsername: "smoke",
    };
    const timeoutReplies: string[] = [];
    let timeoutAborted = false;
    const timeoutSink = {
      emit: async (_channel: string, text: string) => { timeoutReplies.push(text); },
      typing: () => undefined,
      replying: () => undefined,
    };
    await runReplyTaskWithTimeout(
      aiTrigger,
      timeoutSink,
      async (state) => new Promise<void>((resolve) => {
        state.signal.addEventListener("abort", () => {
          timeoutAborted = true;
          resolve();
        }, { once: true });
      }),
      5,
    );
    assertOk(
      "AI 超时会中止底层任务并发送兜底回复",
      timeoutAborted && timeoutReplies.length === 1,
    );
    const backgroundTimeoutReplies: string[] = [];
    await runReplyTaskWithTimeout(
      { ...aiTrigger, origin: "conflict" },
      { ...timeoutSink, emit: async (_channel, value) => { backgroundTimeoutReplies.push(value); } },
      async () => new Promise<void>(() => undefined),
      5,
    );
    assertOk("后台介入 Agent 超时保持沉默", backgroundTimeoutReplies.length === 0);

    const failureOperationLines: string[] = [];
    const originalConsoleInfo = console.info;
    console.info = (...values: unknown[]) => {
      failureOperationLines.push(values.map(String).join(" "));
    };
    try {
      await runReplyTaskWithTimeout(aiTrigger, timeoutSink, async (state) => {
        state.emitted = true;
        state.markFailure(new Error("synthetic_agent_failure"));
      });
    } finally {
      console.info = originalConsoleInfo;
    }
    const failureOperation = failureOperationLines
      .map((line) => {
        try {
          return JSON.parse(line) as Record<string, unknown>;
        } catch {
          return null;
        }
      })
      .find((entry) => entry?.operation === "ai.reply");
    assertOk(
      "Agent 内部失败即使已发兜底也记录为降级失败",
      failureOperation?.status === "error" &&
        failureOperation.emitted === true &&
        failureOperation.degraded === true,
    );

    const { recordAgentTool } = await import("../src/ai/mcp/runContext");
    const toolOperationLines: string[] = [];
    console.info = (...values: unknown[]) => {
      toolOperationLines.push(values.map(String).join(" "));
    };
    try {
      await recordAgentTool({
        identity: {
          traceId: "smoke-tool-trace",
          requesterUsername: "smoke",
          requesterName: "测试用户",
          storedChannel: "ai:smoke",
          expiresAt: Date.now() + 60_000,
        },
        trace: {
          id: "smoke-tool-trace",
          ts: Date.now(),
          status: "running",
          channel: "ai:smoke",
          requesterName: "测试用户",
          question: "",
        },
        actions: [],
        citations: [],
        usedVision: false,
        toolCounts: {},
      }, "search_facts", { query: "never-log-tool-arguments" }, async () => ({
        secret: "never-log-tool-result",
      }));
    } finally {
      console.info = originalConsoleInfo;
    }
    const toolOperationLine = toolOperationLines.find((line) => line.includes("\"operation\":\"ai.tool\""));
    const toolOperation = toolOperationLine
      ? JSON.parse(toolOperationLine) as Record<string, unknown>
      : null;
    assertOk(
      "Agent 工具日志只记录名称、状态、耗时和次数",
      toolOperation?.status === "ok" &&
        toolOperation.tool === "search_facts" &&
        toolOperation.callIndex === 1 &&
        !toolOperationLine?.includes("never-log-tool-arguments") &&
        !toolOperationLine?.includes("never-log-tool-result"),
    );

    const { formatProviderHttpFailure } = await import("../src/ai/provider");
    const providerFailureBody = "never-log-upstream-response-body";
    const providerFailureLog = formatProviderHttpFailure(
      "smoke.provider",
      new Response(providerFailureBody, {
        status: 429,
        headers: {
          "x-request-id": "req-smoke-provider",
          "retry-after": "7",
        },
      }),
    );
    assertOk(
      "AI 上游失败日志只保留状态与安全响应元数据",
      providerFailureLog.includes("HTTP 429")
        && providerFailureLog.includes("request-id=req-smoke-provider")
        && providerFailureLog.includes("retry-after=7")
        && !providerFailureLog.includes(providerFailureBody)
        && !providerFailureLog.includes("body="),
    );

    const embeddings = await import("../src/ai/embeddings");
    const {
      config: runtimeConfig,
      parsePositiveIntegerSetting,
    } = await import("../src/config");
    const expectedVector = new Float32Array(runtimeConfig.embeddingDim);
    expectedVector[0] = 1;
    const mismatchedVector = new Float32Array(
      runtimeConfig.embeddingDim === 1 ? 2 : runtimeConfig.embeddingDim - 1,
    );
    let mismatchedPackRejected = false;
    try {
      embeddings.packVector(mismatchedVector);
    } catch {
      mismatchedPackRejected = true;
    }
    let invalidConfiguredDimensionRejected = false;
    try {
      parsePositiveIntegerSetting("EMBEDDING_DIM", "0", 1024, 65_536);
    } catch {
      invalidConfiguredDimensionRejected = true;
    }
    const packedVector = embeddings.packVector(expectedVector);
    assertOk(
      "Embedding 配置、读写和相似度统一拒绝维度不一致",
      embeddings.similarity(expectedVector, mismatchedVector) === 0
        && mismatchedPackRejected
        && invalidConfiguredDimensionRejected
        && parsePositiveIntegerSetting("EMBEDDING_DIM", "2048", 1024, 65_536) === 2048
        && embeddings.unpackVector(packedVector)?.length === runtimeConfig.embeddingDim
        && embeddings.unpackVector(new Uint8Array(mismatchedVector.byteLength)) === null,
    );

    const startedQuestions: string[] = [];
    let releaseFirst: (() => void) | undefined;
    const firstGate = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const queue = new ReplyQueue(async (trigger) => {
      startedQuestions.push(trigger.question);
      if (trigger.question === "q1") await firstGate;
    }, 2);
    const queueSink = { emit: async () => undefined, typing: () => undefined };
    queue.enqueue({ ...aiTrigger, question: "q1" }, queueSink);
    queue.enqueue({ ...aiTrigger, question: "q2" }, queueSink);
    const overload1 = queue.enqueue({ ...aiTrigger, question: "q3" }, queueSink);
    const overload2 = queue.enqueue({ ...aiTrigger, question: "q4" }, queueSink);
    await new Promise((resolve) => setTimeout(resolve, 5));
    releaseFirst?.();
    await new Promise((resolve) => setTimeout(resolve, 20));
    assertOk(
      "AI 队列过载合并并最终回答最新请求",
      overload1 === "coalesced" && overload2 === "coalesced" && startedQuestions.join(",") === "q1,q2,q4",
    );
    let hangingFallbackAttempts = 0;
    const hangingFallbackStartedAt = Date.now();
    await runReplyTaskWithTimeout(
      { ...aiTrigger, messageId: "smoke-timeout-hanging-fallback" },
      {
        ...timeoutSink,
        emit: async () => {
          hangingFallbackAttempts += 1;
          await new Promise<void>(() => undefined);
        },
      },
      async () => new Promise<void>(() => undefined),
      5,
      undefined,
      10,
    );
    assertOk(
      "AI 超时兜底落库卡住时仍会在写入期限后释放队列",
      hangingFallbackAttempts === 1 && Date.now() - hangingFallbackStartedAt < 250,
    );

    let recalledRunnerAborted = false;
    let recalledUnderlyingEmits = 0;
    const recalledQueue = new ReplyQueue(async (_trigger, guardedSink, signal) => {
      await new Promise<void>((resolve) => {
        const finish = () => {
          recalledRunnerAborted = true;
          void guardedSink.emit("ai:smoke", "不应落库", true)
            .catch(() => undefined)
            .finally(resolve);
        };
        if (signal?.aborted) finish();
        else signal?.addEventListener("abort", finish, { once: true });
      });
    });
    const recalledSink = {
      emit: async () => { recalledUnderlyingEmits += 1; },
      typing: () => undefined,
      replying: () => undefined,
      activity: () => undefined,
    };
    recalledQueue.enqueue(
      { ...aiTrigger, messageId: "smoke-recalled-ai-trigger" },
      recalledSink,
    );
    await new Promise((resolve) => setTimeout(resolve, 5));
    const recalledCancelled = recalledQueue.cancelByMessageId("smoke-recalled-ai-trigger");
    const recalledIdle = await recalledQueue.waitForIdle(250);
    assertOk(
      "撤回触发消息会中止运行中的 Agent 且阻止后续回复落库",
      recalledCancelled === 1 && recalledRunnerAborted && recalledIdle && recalledUnderlyingEmits === 0,
    );

    let shutdownRunnerAborted = false;
    const shutdownQueue = new ReplyQueue(async (_trigger, _sink, signal) => {
      await new Promise<void>((resolve) => {
        const finish = () => {
          shutdownRunnerAborted = true;
          resolve();
        };
        if (signal?.aborted) finish();
        else signal?.addEventListener("abort", finish, { once: true });
      });
    });
    shutdownQueue.enqueue(
      { ...aiTrigger, messageId: "smoke-shutdown-ai-trigger" },
      queueSink,
    );
    await new Promise((resolve) => setTimeout(resolve, 5));
    await shutdownQueue.stop(250);
    const afterShutdownQueueResult = shutdownQueue.enqueue(
      { ...aiTrigger, messageId: "smoke-after-shutdown" },
      queueSink,
    );
    assertOk(
      "AI shutdown 会中止运行任务并拒绝新任务",
      shutdownRunnerAborted && afterShutdownQueueResult === "rejected",
    );

    // 账号
    const { listPublicAccounts } = await import("../src/auth/accounts");
    const accounts = await listPublicAccounts();
    assertOk(`listPublicAccounts → ${accounts.length} 个账号`, accounts.length === 2);

    // 消息：分页 / since / after+before / around / 搜索 / LIKE
    const { subscribeMemoryDomainEvents } = await import("../src/ai/memory/events");
    const stopMemoryEvents = subscribeMemoryDomainEvents();
    const {
      fetchMessageById,
      fetchMessages,
      searchMessages,
      createMessage,
      createMessageWithStatus,
      createAiMessage,
      createAiMessages,
      recallMessage,
      upsertReadReceipt,
      getReadReceipts,
    } = await import("../src/chat/messageService");
    const user = { username: accounts[0].username, name: accounts[0].name };
    const latest = await fetchMessages(user, { channel: "couple", limit: 50 });
    assertOk(`fetchMessages latest → ${latest.length} 条`, latest.length === 50);
    const referenced = await fetchMessageById(user, "couple", latest[0].id);
    assertOk("fetchMessageById 只返回当前会话原消息", referenced?.id === latest[0].id);
    assertOk("ts 是 number", typeof latest[0].ts === "number" && latest[0].ts > 1e12);
    const before = await fetchMessages(user, { channel: "couple", before: latest[0].ts, limit: 20 });
    assertOk(`fetchMessages before → ${before.length} 条且时序正确`, before.length === 20 && before[19].ts <= latest[0].ts);
    const range = await fetchMessages(user, {
      channel: "couple",
      after: latest[0].ts,
      before: latest[latest.length - 1].ts + 1,
      limit: 50,
    });
    assertOk(
      `fetchMessages after+before → ${range.length} 条且在范围内`,
      range.length > 0 &&
        range.every((message) => message.ts >= latest[0].ts && message.ts < latest[latest.length - 1].ts + 1),
    );
    const found = await searchMessages(user, "couple", "喵", 10);
    assertOk(`searchMessages "喵" → ${found.list.length} 条`, found.list.length > 0);
    const nextSearchPage = found.nextCursor
      ? await searchMessages(user, "couple", "喵", 10, found.nextCursor)
      : null;
    const firstSearchIds = new Set(found.list.map((message) => message.id));
    assertOk(
      "searchMessages 使用 (ts,id) 游标继续加载且不重复",
      found.hasMore && nextSearchPage !== null &&
        nextSearchPage.list.length > 0 &&
        nextSearchPage.list.every((message) => !firstSearchIds.has(message.id)),
    );

    // 写入一条新消息（含 reply/meta JSON + clientId 幂等）
    const created = await createMessage(user, { channel: "couple", type: "text", text: "PG 冒烟测试", clientId: "smoke-1" });
    const dup = await createMessage(user, { channel: "couple", type: "text", text: "PG 冒烟测试重复", clientId: "smoke-1" });
    assertOk("clientId 幂等（重发返回同一条）", created.id === dup.id);
    const durableJobBefore = await db.get<{ status: string; attempt_count: number }>(
      "SELECT status, attempt_count FROM ai_reply_jobs WHERE trigger_message_id = ?",
      [created.id],
    );
    const { claimAiReplyJob } = await import("../src/ai/agent/replyJobs");
    const durableClaimed = await claimAiReplyJob(created.id);
    let wrongRequesterRejected = false;
    try {
      await createAiMessages(
        "couple",
        [{ text: "不应由其他成员代写的回复" }],
        { username: accounts[1].username, name: accounts[1].name },
        created.id,
      );
    } catch (error) {
      wrongRequesterRejected = error instanceof Error
        && error.message === "ai_reply_cancelled";
    }
    const durableReplies = await createAiMessages(
      "couple",
      [
        { text: "持久化回复第一段" },
        { text: "持久化回复第二段", meta: { smoke: "last-part" } },
      ],
      user,
      created.id,
    );
    const durableJobAfter = await db.get<{
      status: string;
      reply_message_id: string | null;
    }>(
      "SELECT status, reply_message_id FROM ai_reply_jobs WHERE trigger_message_id = ?",
      [created.id],
    );
    assertOk(
      "AI 回复任务校验请求人，并将多段正文和末段 meta 原子落库后完成",
      durableJobBefore?.status === "pending"
        && durableJobBefore.attempt_count === 0
        && durableClaimed
        && wrongRequesterRejected
        && durableJobAfter?.status === "completed"
        && durableJobAfter.reply_message_id === durableReplies[0].id
        && durableReplies.length === 2
        && durableReplies.every((message) => message.sender === "ai")
        && durableReplies[0].ts < durableReplies[1].ts
        && (durableReplies[1].meta as { smoke?: string } | undefined)?.smoke === "last-part",
    );
    let inactiveIdentityRejected = false;
    try {
      await createAiMessage(
        "couple",
        "失效身份不应落入 legacy 会话",
        undefined,
        { username: "inactive-smoke-account", name: "inactive" },
      );
    } catch (error) {
      inactiveIdentityRejected = error instanceof Error
        && error.message === "unauthorized";
    }
    assertOk("显式失效身份不会回退到 legacy 会话", inactiveIdentityRejected);
    const replied = await createMessage(user, {
      channel: "couple", type: "text", text: "PG 引用测试",
      replyTo: created.id, replyPreview: "PG 冒烟测试",
      clientId: "smoke-reply-1",
    });
    assertOk(
      "消息响应只含扁平引用字段",
      replied.replyTo === created.id && replied.replyPreview === "PG 冒烟测试" && !("reply" in replied),
    );

    // 媒体附件：消息只能绑定当前用户未使用过的 uploadId，绑定和消息写入必须一起提交。
    const uploadId = "up_smoke_media_123";
    const uploadURL = "https://example.com/uploads/up_smoke_media_123.jpg";
    const mediaPath = path.join(dataDir, "up_smoke_media_123.jpg");
    const { createImageThumbnail, thumbnailPathFor } = await import("../src/upload/thumbnail");
    const mediaThumbnailPath = thumbnailPathFor(mediaPath);
    fs.writeFileSync(mediaPath, "media");
    fs.writeFileSync(mediaThumbnailPath, "thumbnail");
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [uploadId, user.username, mediaPath, uploadURL, "image/jpeg", 5, Date.now()],
    );
    const media = await createMessage(user, {
      channel: "couple", type: "image", text: "[图片]", url: uploadURL, uploadId, clientId: "smoke-media-1",
    });
    const boundUpload = await db.get<{ message_id: string | null }>("SELECT message_id FROM uploads WHERE id = ?", [uploadId]);
    assertOk("媒体消息原子绑定 upload", media.url === uploadURL && boundUpload?.message_id === media.id);
    let duplicateAttachmentRejected = false;
    try {
      await createMessage(user, {
        channel: "couple", type: "image", text: "[图片]", url: uploadURL, uploadId, clientId: "smoke-media-2",
      });
    } catch {
      duplicateAttachmentRejected = true;
    }
    assertOk("同一 upload 不能绑定两条消息", duplicateAttachmentRejected);
    const mismatchedUploadId = "up_smoke_mime_mismatch";
    const mismatchedUploadPath = path.join(dataDir, "smoke-mime-mismatch.pdf");
    fs.writeFileSync(mismatchedUploadPath, "%PDF-smoke");
    await db.run(
      `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'message')`,
      [
        mismatchedUploadId,
        user.username,
        mismatchedUploadPath,
        "https://example.com/smoke-mime-mismatch.pdf",
        "application/pdf",
        10,
        Date.now(),
      ],
    );
    let mimeMismatchError = "";
    try {
      await createMessage(user, {
        channel: "couple",
        type: "image",
        text: "[图片]",
        uploadId: mismatchedUploadId,
        clientId: "smoke-mime-mismatch",
      });
    } catch (error) {
      mimeMismatchError = error instanceof Error ? error.message : String(error);
    }
    const mismatchedUpload = await db.get<{ message_id: string | null }>(
      "SELECT message_id FROM uploads WHERE id = ?",
      [mismatchedUploadId],
    );
    const mismatchedMessage = await db.get<{ id: string }>(
      "SELECT id FROM messages WHERE sender = ? AND client_id = ?",
      [user.username, "smoke-mime-mismatch"],
    );
    assertOk(
      "旧单附件路径拒绝 MIME 与消息类型错配且事务不绑定文件",
      mimeMismatchError === "upload_message_type_mismatch" &&
        mismatchedUpload?.message_id === null &&
        !mismatchedMessage,
    );
    const wrongPurposeUploadId = "up_smoke_wrong_purpose";
    const wrongPurposeUploadPath = path.join(dataDir, "smoke-wrong-purpose.jpg");
    fs.writeFileSync(wrongPurposeUploadPath, "image");
    await db.run(
      `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
       VALUES (?, ?, ?, ?, 'image/jpeg', 5, ?, 'avatar')`,
      [
        wrongPurposeUploadId,
        user.username,
        wrongPurposeUploadPath,
        "https://example.com/smoke-wrong-purpose.jpg",
        Date.now(),
      ],
    );
    let wrongMessagePurposeError = "";
    try {
      await createMessage(user, {
        channel: "couple",
        type: "image",
        text: "[图片]",
        uploadId: wrongPurposeUploadId,
        clientId: "smoke-wrong-purpose",
      });
    } catch (error) {
      wrongMessagePurposeError = error instanceof Error ? error.message : String(error);
    }
    const wrongPurposeUpload = await db.get<{ message_id: string | null; purpose: string }>(
      "SELECT message_id, purpose FROM uploads WHERE id = ?",
      [wrongPurposeUploadId],
    );
    assertOk(
      "消息附件拒绝跨 purpose 复用且事务不改变上传记录",
      wrongMessagePurposeError === "upload_purpose_mismatch" &&
        wrongPurposeUpload?.message_id === null &&
        wrongPurposeUpload.purpose === "avatar",
    );
    const recalledMedia = await recallMessage(user, media.id);
    let recalledUpload = await db.get<{ id: string }>("SELECT id FROM uploads WHERE id = ?", [uploadId]);
    for (
      let attempt = 0;
      attempt < 50 && (recalledUpload || fs.existsSync(mediaPath) || fs.existsSync(mediaThumbnailPath));
      attempt += 1
    ) {
      await new Promise((resolve) => setTimeout(resolve, 10));
      recalledUpload = await db.get<{ id: string }>("SELECT id FROM uploads WHERE id = ?", [uploadId]);
    }
    assertOk(
      "撤回媒体消息同时删除附件",
      recalledMedia?.id === media.id && !recalledUpload &&
        !fs.existsSync(mediaPath) && !fs.existsSync(mediaThumbnailPath),
    );

    const voiceMetaUploadId = "up_smoke_voice_meta";
    const voiceMetaPath = path.join(dataDir, "smoke-voice-meta.m4a");
    fs.writeFileSync(voiceMetaPath, "voice");
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [
        voiceMetaUploadId,
        user.username,
        voiceMetaPath,
        "https://example.com/voice-meta.m4a",
        "audio/m4a",
        5,
        Date.now(),
      ],
    );
    const voiceWithDuration = await createMessage(user, {
      channel: "couple",
      type: "voice",
      text: "[语音]",
      uploadId: voiceMetaUploadId,
      clientId: "smoke-voice-meta-1",
      meta: { media: { durationMs: 12_345 } },
    });
    const returnedVoiceMeta = voiceWithDuration.meta as {
      media?: { durationMs?: number };
    } | null;
    assertOk(
      "语音时长元数据随消息持久化并返回",
      returnedVoiceMeta?.media?.durationMs === 12_345,
    );
    await recallMessage(user, voiceWithDuration.id);

    // 相册/Live Photo：一条逻辑消息原子绑定静态图与 paired video，撤回整组清理。
    const albumPhotoId = "up_smoke_album_photo";
    const albumMotionId = "up_smoke_album_motion";
    const albumPhotoPath = path.join(dataDir, "smoke-album.jpg");
    const albumPhotoThumbnailPath = thumbnailPathFor(albumPhotoPath);
    const albumMotionPath = path.join(dataDir, "smoke-album.mov");
    fs.writeFileSync(albumPhotoPath, "photo");
    fs.writeFileSync(albumPhotoThumbnailPath, "thumbnail");
    fs.writeFileSync(albumMotionPath, "motion");
    await db.run(
      `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        albumPhotoId, user.username, albumPhotoPath, "https://example.com/album.jpg", "image/jpeg", 5, Date.now(), "message",
        albumMotionId, user.username, albumMotionPath, "https://example.com/album.mov", "video/quicktime", 6, Date.now(), "message",
      ],
    );
    const album = await createMessage(user, {
      channel: "couple", type: "image", text: "[实况照片]", clientId: "smoke-album-1",
      attachments: [
        { assetId: "asset_live_1", role: "photo", uploadId: albumPhotoId, order: 0 },
        { assetId: "asset_live_1", role: "pairedVideo", uploadId: albumMotionId, order: 0 },
      ],
    });
    const albumBindings = await db.all<{ message_id: string }>(
      "SELECT message_id FROM uploads WHERE id IN (?, ?) ORDER BY id", [albumPhotoId, albumMotionId],
    );
    assertOk(
      "相册消息原子绑定多附件",
      album.attachments?.length === 2 && album.url === "https://example.com/album.jpg" &&
        albumBindings.length === 2 && albumBindings.every((row) => row.message_id === album.id),
    );
    await recallMessage(user, album.id);
    let remainingAlbumUploads = await db.all<{ id: string }>(
      "SELECT id FROM uploads WHERE id IN (?, ?)", [albumPhotoId, albumMotionId],
    );
    for (
      let attempt = 0;
      attempt < 50 && (
        remainingAlbumUploads.length > 0 ||
        fs.existsSync(albumPhotoPath) ||
        fs.existsSync(albumPhotoThumbnailPath) ||
        fs.existsSync(albumMotionPath)
      );
      attempt += 1
    ) {
      await new Promise((resolve) => setTimeout(resolve, 10));
      remainingAlbumUploads = await db.all<{ id: string }>(
        "SELECT id FROM uploads WHERE id IN (?, ?)", [albumPhotoId, albumMotionId],
      );
    }
    assertOk(
      "撤回相册消息清理整组附件",
      remainingAlbumUploads.length === 0 &&
        !fs.existsSync(albumPhotoPath) &&
        !fs.existsSync(albumPhotoThumbnailPath) &&
        !fs.existsSync(albumMotionPath),
    );
    // 只清理明确用于消息且超过 24h 仍未绑定的文件；头像/贴纸不误删。
    const abandonedPath = path.join(dataDir, "abandoned-message.jpg");
    const abandonedThumbnailPath = thumbnailPathFor(abandonedPath);
    const avatarPath = path.join(dataDir, "keep-avatar.jpg");
    const duplicatePhysicalPath = path.join(dataDir, "shared-physical-file.jpg");
    fs.writeFileSync(abandonedPath, "abandoned");
    fs.writeFileSync(abandonedThumbnailPath, "thumbnail");
    fs.writeFileSync(avatarPath, "avatar");
    fs.writeFileSync(duplicatePhysicalPath, "shared-file");
    const oldCreatedAt = Date.now() - 2 * 24 * 60 * 60 * 1000;
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      ["up_abandoned_123", user.username, abandonedPath, "https://example.com/abandoned.jpg", "image/jpeg", 9, oldCreatedAt, "message"],
    );
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      ["up_avatar_keep_123", user.username, avatarPath, "https://example.com/avatar.jpg", "image/jpeg", 6, oldCreatedAt, "avatar"],
    );
    await db.run(
      `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
       VALUES (?, ?, ?, ?, 'image/jpeg', 11, ?, 'message'),
              (?, ?, ?, ?, 'image/jpeg', 11, ?, 'avatar')`,
      [
        "up_duplicate_abandoned_123",
        user.username,
        duplicatePhysicalPath,
        "https://example.com/duplicate-abandoned.jpg",
        oldCreatedAt,
        "up_duplicate_retained_123",
        user.username,
        duplicatePhysicalPath,
        "https://example.com/duplicate-retained.jpg",
        Date.now(),
      ],
    );
    const {
      cleanupAbandonedMessageUploads,
      cleanupUnreferencedSharedUploads,
      drainFileCleanupQueue,
    } = await import("../src/upload/cleanup");
    const cleaned = await cleanupAbandonedMessageUploads();
    const queuedAbandoned = await db.get<{ completed_at: number | null }>(
      "SELECT completed_at FROM file_cleanup_queue WHERE path = ? ORDER BY created_at DESC LIMIT 1",
      [abandonedPath],
    );
    const removedAbandonedUpload = await db.get<{ id: string }>(
      "SELECT id FROM uploads WHERE id = ?",
      ["up_abandoned_123"],
    );
    const keptAvatar = await db.get<{ id: string }>("SELECT id FROM uploads WHERE id = ?", ["up_avatar_keep_123"]);
    const duplicateCleanup = await db.get<{ id: string }>(
      "SELECT id FROM file_cleanup_queue WHERE path = ?",
      [duplicatePhysicalPath],
    );
    assertOk(
      "过期消息附件先原子移除元数据，且共享物理路径仍有引用时不排队删除",
      cleaned === 2 &&
        !removedAbandonedUpload &&
        queuedAbandoned?.completed_at === null &&
        !duplicateCleanup &&
        fs.existsSync(abandonedPath) &&
        fs.existsSync(abandonedThumbnailPath) &&
        fs.existsSync(duplicatePhysicalPath) &&
        fs.existsSync(avatarPath) &&
        keptAvatar?.id === "up_avatar_keep_123",
    );
    const drainedAbandoned = await drainFileCleanupQueue();
    assertOk(
      "可靠清理队列删除过期附件原文件与缩略图且不误删头像",
      drainedAbandoned >= 1 &&
        !fs.existsSync(abandonedPath) &&
        !fs.existsSync(abandonedThumbnailPath) &&
        fs.existsSync(duplicatePhysicalPath) &&
        fs.existsSync(avatarPath),
    );

    const unusedAvatarPath = path.join(dataDir, "unused-avatar.jpg");
    const activeStickerPath = path.join(dataDir, "active-sticker.png");
    const tombstoneStickerPath = path.join(dataDir, "tombstone-sticker.png");
    const historyStickerPath = path.join(dataDir, "history-sticker.png");
    const partnerStickerPath = path.join(dataDir, "partner-sticker.png");
    const foreignStickerPath = path.join(dataDir, "foreign-sticker.png");
    const legacyAvatarFilename = "1783639852452-aaaaaaaaaaaa.jpg";
    const legacyAvatarPath = path.join(dataDir, legacyAvatarFilename);
    for (const fixturePath of [
      unusedAvatarPath,
      activeStickerPath,
      tombstoneStickerPath,
      historyStickerPath,
      partnerStickerPath,
      foreignStickerPath,
      legacyAvatarPath,
    ]) {
      fs.writeFileSync(fixturePath, "shared-media");
    }
    const sharedUploadFixtures = [
      ["up_avatar_unused_123", unusedAvatarPath, "avatar"],
      ["up_sticker_active_123", activeStickerPath, "sticker"],
      ["up_sticker_tombstone_123", tombstoneStickerPath, "sticker"],
      ["up_sticker_history_123", historyStickerPath, "sticker"],
      ["up_sticker_partner_123", partnerStickerPath, "sticker"],
    ] as const;
    for (const [id, fixturePath, purpose] of sharedUploadFixtures) {
      await db.run(
        `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
         VALUES (?, ?, ?, ?, 'image/png', ?, ?, ?)`,
        [
          id,
          user.username,
          fixturePath,
          `http://127.0.0.1:8080/media/${id}?sig=expired&exp=1`,
          12,
          oldCreatedAt,
          purpose,
        ],
      );
    }
    await db.run(
      `UPDATE uploads SET owner = ? WHERE id = ?`,
      [accounts[1].username, "up_sticker_partner_123"],
    );
    await db.run(
      `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
       VALUES (?, 'outside-couple', ?, ?, 'image/png', 12, ?, 'sticker')`,
      [
        "up_sticker_foreign_123",
        foreignStickerPath,
        "http://127.0.0.1:8080/media/up_sticker_foreign_123?sig=expired&exp=1",
        Date.now(),
      ],
    );
    await db.run(
      `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
       VALUES (?, ?, ?, ?, 'image/jpeg', 12, ?, 'avatar')`,
      [
        "legacy_avatar_shared_123",
        user.username,
        legacyAvatarPath,
        `https://old.example/uploads/${legacyAvatarFilename}`,
        oldCreatedAt,
      ],
    );
    const { setSharedItem: setSharedMediaItem, getSharedState: getSharedMediaState } = await import(
      "../src/shared/sharedService"
    );
    await setSharedMediaItem(user, `avatar_${user.username}`, {
      url: "http://127.0.0.1:8080/media/up_avatar_keep_123?sig=expired&exp=1",
    });
    await setSharedMediaItem(user, "avatar_legacy_smoke", {
      url: `/uploads/${legacyAvatarFilename}`,
    });
    await setSharedMediaItem(user, "stickers_user_smoke", {
      version: 3,
      items: [{
        id: "sticker-active",
        url: "http://127.0.0.1:8080/media/up_sticker_active_123?sig=expired&exp=1",
        groupId: "default",
        addedAt: 1,
        updatedAt: 1,
      }],
      groups: [],
      itemTombstones: [{
        url: "http://127.0.0.1:8080/media/up_sticker_tombstone_123?sig=expired&exp=1",
        deletedAt: 2,
      }],
      groupTombstones: [],
    });
    const historySticker = await createMessage(user, {
      channel: "couple",
      type: "sticker",
      text: "[表情]",
      url: "http://127.0.0.1:8080/media/up_sticker_history_123?sig=expired&exp=1",
      clientId: "smoke-sticker-history",
    });
    const partnerSticker = await createMessage(user, {
      channel: "couple",
      type: "sticker",
      text: "[表情]",
      url: "http://127.0.0.1:8080/media/up_sticker_partner_123?sig=expired&exp=1",
      clientId: "smoke-sticker-partner",
    });
    const reversedSharedStickerItems = [
      {
        id: "sticker-active-lock",
        url: "http://127.0.0.1:8080/media/up_sticker_active_123?sig=expired&exp=1",
        groupId: "default",
        addedAt: 1,
        updatedAt: 1,
      },
      {
        id: "sticker-partner-lock",
        url: "http://127.0.0.1:8080/media/up_sticker_partner_123?sig=expired&exp=1",
        groupId: "default",
        addedAt: 1,
        updatedAt: 1,
      },
    ];
    await Promise.all([
      setSharedMediaItem(user, "stickers_user_lock_order_a", {
        version: 3,
        items: reversedSharedStickerItems,
      }),
      setSharedMediaItem(user, "stickers_user_lock_order_b", {
        version: 3,
        items: [...reversedSharedStickerItems].reverse(),
      }),
    ]);
    let wrongPurposeStickerError = "";
    try {
      await createMessage(user, {
        channel: "couple",
        type: "sticker",
        text: "[表情]",
        url: "http://127.0.0.1:8080/media/up_avatar_keep_123?sig=expired&exp=1",
        clientId: "smoke-sticker-wrong-purpose",
      });
    } catch (error) {
      wrongPurposeStickerError = error instanceof Error ? error.message : String(error);
    }
    let foreignStickerMessageError = "";
    try {
      await createMessage(user, {
        channel: "couple",
        type: "sticker",
        text: "[表情]",
        url: "http://127.0.0.1:8080/media/up_sticker_foreign_123?sig=expired&exp=1",
        clientId: "smoke-sticker-foreign",
      });
    } catch (error) {
      foreignStickerMessageError = error instanceof Error ? error.message : String(error);
    }
    let externalStickerMessageError = "";
    try {
      await createMessage(user, {
        channel: "couple",
        type: "sticker",
        text: "[表情]",
        url: "https://external.example/media/up_sticker_active_123?sig=external&exp=9999999999999",
        clientId: "smoke-sticker-external",
      });
    } catch (error) {
      externalStickerMessageError = error instanceof Error ? error.message : String(error);
    }
    let foreignSharedStickerError = "";
    try {
      await setSharedMediaItem(user, "stickers_user_foreign_smoke", {
        version: 3,
        items: [{
          id: "sticker-foreign",
          url: "http://127.0.0.1:8080/media/up_sticker_foreign_123?sig=expired&exp=1",
        }],
      });
    } catch (error) {
      foreignSharedStickerError = error instanceof Error ? error.message : String(error);
    }
    let externalSharedMediaError = "";
    try {
      await setSharedMediaItem(user, "avatar_external_smoke", {
        url: "https://external.example/media/up_sticker_active_123?sig=external&exp=9999999999999",
      });
    } catch (error) {
      externalSharedMediaError = error instanceof Error ? error.message : String(error);
    }
    const refreshedSharedMedia = await getSharedMediaState(user);
    const refreshedAvatarURL = (refreshedSharedMedia[`avatar_${user.username}`]?.value as {
      url?: string;
    } | undefined)?.url;
    const refreshedStickerURL = (refreshedSharedMedia.stickers_user_smoke?.value as {
      items?: Array<{ url?: string }>;
    } | undefined)?.items?.[0]?.url;
    assertOk(
      "共享媒体刷新签名、统一锁序，并按用途、同源与情侣租户校验引用",
      Number(new URL(refreshedAvatarURL ?? "http://invalid").searchParams.get("exp")) > Date.now() &&
        Number(new URL(refreshedStickerURL ?? "http://invalid").searchParams.get("exp")) > Date.now() &&
        historySticker.url?.includes("/media/up_sticker_history_123?") === true &&
        partnerSticker.url?.includes("/media/up_sticker_partner_123?") === true &&
        wrongPurposeStickerError === "upload_purpose_mismatch" &&
        foreignStickerMessageError === "upload_not_found" &&
        externalStickerMessageError === "upload_not_found" &&
        foreignSharedStickerError === "upload_not_found" &&
        externalSharedMediaError === "upload_not_found",
    );

    const queuedSharedMedia = await cleanupUnreferencedSharedUploads();
    const retainedSharedUploads = await db.all<{ id: string }>(
      `SELECT id FROM uploads
        WHERE id IN (?, ?, ?, ?) ORDER BY id`,
      [
        "up_avatar_keep_123",
        "up_sticker_active_123",
        "up_sticker_history_123",
        "legacy_avatar_shared_123",
      ],
    );
    const removedSharedUploads = await db.all<{ id: string }>(
      `SELECT id FROM uploads
        WHERE id IN (?, ?)`,
      ["up_avatar_unused_123", "up_sticker_tombstone_123"],
    );
    assertOk(
      "共享媒体 GC 保留活跃头像、贴纸库和历史消息引用，仅回收无引用与墓碑文件",
      queuedSharedMedia === 2 &&
        retainedSharedUploads.length === 4 &&
        removedSharedUploads.length === 0 &&
        fs.existsSync(unusedAvatarPath) &&
        fs.existsSync(tombstoneStickerPath),
    );
    const drainedSharedMedia = await drainFileCleanupQueue();
    assertOk(
      "共享媒体可靠队列提交后才删除原文件",
      drainedSharedMedia >= 2 &&
        !fs.existsSync(unusedAvatarPath) &&
        !fs.existsSync(tombstoneStickerPath) &&
        fs.existsSync(avatarPath) &&
        fs.existsSync(activeStickerPath) &&
        fs.existsSync(historyStickerPath) &&
        fs.existsSync(legacyAvatarPath),
    );
    await db.run(
      `INSERT INTO file_cleanup_queue (id, path, reason, created_at)
       VALUES (?, ?, 'boundary_smoke', ?)`,
      ["cleanup_upload_root_boundary", dataDir, Date.now()],
    );
    await drainFileCleanupQueue();
    const rejectedRootCleanup = await db.get<{ completed_at: number | null; last_error: string | null }>(
      "SELECT completed_at, last_error FROM file_cleanup_queue WHERE id = ?",
      ["cleanup_upload_root_boundary"],
    );
    assertOk(
      "可靠清理队列拒绝把上传目录本身作为文件目标",
      rejectedRootCleanup?.completed_at === null &&
        rejectedRootCleanup.last_error === "path_outside_upload_dir" &&
        fs.existsSync(dataDir),
    );

    const bindingRacePath = path.join(dataDir, "binding-race.jpg");
    fs.writeFileSync(bindingRacePath, "binding-race");
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        "up_binding_race_123",
        user.username,
        bindingRacePath,
        "https://example.com/binding-race.jpg",
        "image/jpeg",
        12,
        oldCreatedAt,
        "message",
      ],
    );
    let markBindingLocked: (() => void) | undefined;
    let releaseBinding: (() => void) | undefined;
    const bindingLocked = new Promise<void>((resolve) => { markBindingLocked = resolve; });
    const bindingGate = new Promise<void>((resolve) => { releaseBinding = resolve; });
    const binding = db.transaction(async (transaction) => {
      const upload = await transaction.get<{ id: string }>(
        "SELECT id FROM uploads WHERE id = ? FOR UPDATE",
        ["up_binding_race_123"],
      );
      if (!upload) throw new Error("binding race fixture missing");
      markBindingLocked?.();
      await bindingGate;
      await transaction.run(
        "UPDATE uploads SET message_id = ? WHERE id = ?",
        [created.id, "up_binding_race_123"],
      );
    });
    await bindingLocked;
    const skippedBinding = await cleanupAbandonedMessageUploads();
    releaseBinding?.();
    await binding;
    const boundDuringCleanup = await db.get<{ message_id: string | null }>(
      "SELECT message_id FROM uploads WHERE id = ?",
      ["up_binding_race_123"],
    );
    const queuedBindingCleanup = await db.get<{ count: number }>(
      "SELECT COUNT(*)::int AS count FROM file_cleanup_queue WHERE path = ?",
      [bindingRacePath],
    );
    assertOk(
      "清理用 SKIP LOCKED 避让正在绑定的附件",
      skippedBinding === 0 &&
        boundDuringCleanup?.message_id === created.id &&
        queuedBindingCleanup?.count === 0 &&
        fs.existsSync(bindingRacePath),
    );

    const thumbnailSourcePath = path.join(dataDir, "thumbnail-source.png");
    const generatedThumbnailPath = thumbnailPathFor(thumbnailSourcePath);
    const sharp = (await import("sharp")).default;
    await sharp({
      create: {
        width: 1_400,
        height: 900,
        channels: 3,
        background: { r: 238, g: 125, b: 162 },
      },
    }).png().toFile(thumbnailSourcePath);
    const thumbnailCreated = await createImageThumbnail(
      thumbnailSourcePath,
      generatedThumbnailPath,
      "image/png",
    );
    const thumbnailMetadata = thumbnailCreated
      ? await sharp(generatedThumbnailPath).metadata()
      : undefined;
    assertOk(
      "静态图片上传生成最长边 720px 的 JPEG 缩略图",
      thumbnailCreated &&
        thumbnailMetadata?.format === "jpeg" &&
        thumbnailMetadata.width === 720 &&
        thumbnailMetadata.height === 463,
    );

    const {
      signedMediaURL,
      signedMediaThumbnailURL,
      signMediaId,
      verifyMediaSignature,
      parseRequestedByteRange,
      mediaUploadIdFromUrl,
      refreshSignedMediaUrl,
    } = await import("../src/upload/mediaAccess");
    const signedURL = new URL(signedMediaURL("up_signature_123"));
    const signedThumbnailURL = new URL(signedMediaThumbnailURL("up_signature_123"));
    const signature = signedURL.searchParams.get("sig") ?? "";
    const exp = Number(signedURL.searchParams.get("exp") ?? "0");
    const signed = signMediaId("up_signature_123", exp);
    assertOk(
      "新媒体 URL 使用 HMAC 签名与过期时间",
      signedURL.pathname === "/media/up_signature_123" &&
        signedThumbnailURL.pathname === "/media/up_signature_123/thumbnail" &&
        signedThumbnailURL.searchParams.has("sig") &&
        signedThumbnailURL.searchParams.has("exp") &&
        Number.isFinite(exp) && exp > Date.now() &&
        signature === signed.sig &&
        verifyMediaSignature("up_signature_123", signature, exp) &&
        !verifyMediaSignature("up_signature_456", signature, exp) &&
        !verifyMediaSignature("up_signature_123", signature, Date.now() - 1_000) &&
        new URL(refreshSignedMediaUrl(signedThumbnailURL.toString()) ?? "").pathname
          === "/media/up_signature_123/thumbnail" &&
        refreshSignedMediaUrl(
          "https://external.example/media/up_signature_123?sig=external&exp=9999999999999",
        ) === "https://external.example/media/up_signature_123?sig=external&exp=9999999999999" &&
        mediaUploadIdFromUrl("/media/up_signature_123?sig=relative") === "up_signature_123" &&
        mediaUploadIdFromUrl(
          " \thttps://external.example/media/up_signature_123?sig=whitespace",
        ) === undefined &&
        mediaUploadIdFromUrl("\\\\external.example\\media\\up_signature_123") === undefined,
    );
    const suffixRange = parseRequestedByteRange("bytes=-500", 10_000);
    assertOk(
      "媒体 suffix Range 指向文件尾部（支持视频分段读取）",
      suffixRange?.start === 9_500 && suffixRange.end === 9_999,
    );
    assertOk(
      "媒体 Range 解析拒绝多段、越界、空 suffix 和非正文件长度",
      parseRequestedByteRange("bytes=0-1,4-5", 10_000) === null &&
        parseRequestedByteRange("bytes=10000-", 10_000) === null &&
        parseRequestedByteRange("bytes=-0", 10_000) === null &&
        parseRequestedByteRange("bytes=0-1", 0) === null,
    );
    const routeMediaId = "up_signed_route_123";
    const routeMediaPath = path.join(dataDir, `${routeMediaId}.txt`);
    const routeThumbnailPath = thumbnailPathFor(routeMediaPath);
    fs.writeFileSync(routeMediaPath, "signed-media");
    fs.writeFileSync(routeThumbnailPath, "signed-thumb");
    const routeMediaURL = signedMediaURL(routeMediaId);
    const routeThumbnailURL = signedMediaThumbnailURL(routeMediaId);
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [routeMediaId, user.username, routeMediaPath, routeMediaURL, "image/jpeg", 12, Date.now(), "avatar"],
    );
    const compatibleRouteFilename = "1783639852451-95c29e3767ff.jpg";
    const compatibleRoutePath = path.join(dataDir, compatibleRouteFilename);
    fs.writeFileSync(compatibleRoutePath, "compatible-media");
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        "compatible_route_timestamp_hash", user.username, compatibleRoutePath,
        `https://example.com/uploads/${compatibleRouteFilename}`, "image/jpeg", 16, Date.now(), "legacy",
      ],
    );
    const { createDeviceSession } = await import("../src/auth/devices");
    const { createToken } = await import("../src/auth/token");
    const currentUser = await createDeviceSession({
      ...user,
      accountId: `acc_legacy_${user.username}`,
      coupleId: "cpl_legacy_xusi",
      memberId: `mem_legacy_${user.username}`,
    }, {
      installationId: "smoke-installation-123",
      platform: "ios",
      deviceName: "smoke",
      appVersion: "0.2.0",
      buildNumber: "11",
      locale: "zh_CN",
      timezone: "Asia/Shanghai",
    });
    const partnerAccount = accounts.find((account) => account.username !== user.username)!;
    const partnerUser = await createDeviceSession({
      username: partnerAccount.username,
      name: partnerAccount.name,
      accountId: `acc_legacy_${partnerAccount.username}`,
      coupleId: "cpl_legacy_xusi",
      memberId: `mem_legacy_${partnerAccount.username}`,
    }, {
      installationId: "smoke-installation-partner-123",
      platform: "ios",
      deviceName: "smoke-partner",
      appVersion: "0.2.0",
      buildNumber: "11",
      locale: "zh_CN",
      timezone: "Asia/Shanghai",
    });
    assertOk(
      "双方登录均生成设备绑定 session",
      Boolean(currentUser?.sessionId && currentUser.deviceId && partnerUser?.sessionId && partnerUser.deviceId),
    );
    const secondCurrentUser = await createDeviceSession({
      ...user,
      accountId: `acc_legacy_${user.username}`,
      coupleId: "cpl_legacy_xusi",
      memberId: `mem_legacy_${user.username}`,
    }, {
      installationId: "smoke-installation-second-123",
      platform: "ios",
      deviceName: "smoke-second",
      appVersion: "0.2.0",
      buildNumber: "11",
      locale: "zh_CN",
      timezone: "Asia/Shanghai",
    });
    const { createRealtimeMessageUseCases } = await import("../src/chat/realtimeUseCases");
    let retryPushCount = 0;
    let retryAiCount = 0;
    const retryUseCases = createRealtimeMessageUseCases({} as Server, {
      createMessage: createMessageWithStatus,
      pushCoupleMessage: async () => {
        retryPushCount += 1;
        throw new Error("expected smoke push failure");
      },
      handleUserMessage: () => {
        retryAiCount += 1;
        throw new Error("expected smoke AI dispatch failure");
      },
    });
    const concurrentPayload = {
      channel: "couple" as const,
      type: "text" as const,
      text: "并发幂等消息",
      clientId: "smoke-concurrent-client-id",
    };
    const [concurrentFirst, concurrentSecond] = await Promise.all([
      retryUseCases.send(currentUser!, concurrentPayload, "smoke-concurrent-1"),
      retryUseCases.send(currentUser!, concurrentPayload, "smoke-concurrent-2"),
    ]);
    const concurrentRetry = await retryUseCases.send(
      currentUser!,
      concurrentPayload,
      "smoke-concurrent-3",
    );
    const concurrentRows = await db.get<{ count: number }>(
      `SELECT COUNT(*)::int AS count FROM messages
        WHERE conversation_id = 'conv_legacy_couple'
          AND sender_account_id = ? AND origin_device_id = ? AND client_id = ?`,
      [currentUser!.accountId, currentUser!.deviceId, concurrentPayload.clientId],
    );
    assertOk(
      "同设备并发 clientId 只创建一次、隔离后台失败且重试不重复 AI/推送",
      concurrentFirst.message.id === concurrentSecond.message.id &&
        concurrentRetry.message.id === concurrentFirst.message.id &&
        Number(concurrentFirst.created) + Number(concurrentSecond.created) === 1 &&
        !concurrentRetry.created &&
        concurrentRows?.count === 1 &&
        retryPushCount === 1 &&
        retryAiCount === 1,
    );
    const sharedClientId = "smoke-shared-client-id";
    const firstDeviceMessage = await createMessageWithStatus(currentUser!, {
      channel: "couple",
      type: "text",
      text: "设备一",
      clientId: sharedClientId,
    });
    const secondDeviceMessage = await createMessageWithStatus(secondCurrentUser!, {
      channel: "couple",
      type: "text",
      text: "设备二",
      clientId: sharedClientId,
    });
    assertOk(
      "不同设备可独立使用相同 clientId",
      firstDeviceMessage.created &&
        secondDeviceMessage.created &&
        firstDeviceMessage.message.id !== secondDeviceMessage.message.id,
    );

    const { buildApp, sanitizeRequestUrl } = await import("../src/app");
    const edgeNginx = fs.readFileSync(
      path.resolve("deploy", "nginx-japan-edge-hoo66.top.conf"),
      "utf8",
    );
    assertOk(
      "应用与边缘代理不记录签名媒体 query",
      sanitizeRequestUrl("/media/up_secret?sig=never-log&exp=999") === "/media/up_secret" &&
        /location \^~ \/media\/\s*\{[\s\S]*?access_log off;/.test(edgeNginx),
    );
    const app = await buildApp();
    app.get("/__smoke/client-ip", async (request) => ({ ip: request.ip }));
    const authorization = `Bearer ${createToken(currentUser!)}`;
    const partnerAuthorization = `Bearer ${createToken(partnerUser!)}`;
    const trustedProxyIpResponse = await app.inject({
      method: "GET",
      url: "/__smoke/client-ip",
      headers: { "x-forwarded-for": "198.51.100.27" },
      remoteAddress: "127.0.0.1",
    });
    const anonymousAccountsResponse = await app.inject({ method: "GET", url: "/api/accounts" });
    const invalidTokenAccountsResponse = await app.inject({
      method: "GET",
      url: "/api/accounts",
      headers: { authorization: "Bearer invalid-token" },
    });
    const authenticatedAccountsResponse = await app.inject({
      method: "GET",
      url: "/api/accounts",
      headers: { authorization },
    });
    const anonymousAccounts = anonymousAccountsResponse.json() as Array<{ username?: string }>;
    const invalidTokenAccounts = invalidTokenAccountsResponse.json() as Array<{ username?: string }>;
    const authenticatedAccounts = authenticatedAccountsResponse.json() as Array<{ username?: string }>;
    assertOk(
      "账号列表保持匿名、无效 token 可用且有效 token 可识别",
      anonymousAccountsResponse.statusCode === 200 &&
        invalidTokenAccountsResponse.statusCode === 200 &&
        authenticatedAccountsResponse.statusCode === 200 &&
        anonymousAccounts.length === 2 &&
        invalidTokenAccounts.length === 2 &&
        authenticatedAccounts.length === 2 &&
        JSON.stringify(invalidTokenAccounts) === JSON.stringify(anonymousAccounts),
    );
    assertOk(
      "Fastify 仅经受控回环/Tailnet 代理还原客户端 IP",
      trustedProxyIpResponse.statusCode === 200 &&
        trustedProxyIpResponse.json<{ ip: string }>().ip === "198.51.100.27",
    );

    const expiredAlbumUploadId = "up_album_expired_123";
    const expiredAlbumPath = path.join(dataDir, `${expiredAlbumUploadId}.mov`);
    const expiredAlbumAt = Date.now() - 60_000;
    const expiredAlbumSignature = signMediaId(expiredAlbumUploadId, expiredAlbumAt);
    const expiredAlbumURL = new URL(`/media/${expiredAlbumUploadId}`, signedURL.origin);
    expiredAlbumURL.searchParams.set("sig", expiredAlbumSignature.sig);
    expiredAlbumURL.searchParams.set("exp", String(expiredAlbumSignature.exp));
    fs.writeFileSync(expiredAlbumPath, "album-video");
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        expiredAlbumUploadId, currentUser!.username, expiredAlbumPath, expiredAlbumURL.toString(),
        "video/quicktime", 11, Date.now(), "album",
      ],
    );
    const albumCreateResponse = await app.inject({
      method: "POST",
      url: "/api/v2/albums",
      headers: { authorization },
      payload: { title: "签名刷新相册", summary: "" },
    });
    const albumCreateBody = albumCreateResponse.json() as { album?: { id?: string } };
    const signedAlbumId = albumCreateBody.album?.id ?? "";
    const albumAddResponse = await app.inject({
      method: "POST",
      url: `/api/v2/albums/${signedAlbumId}/items/from-upload`,
      headers: { authorization },
      payload: { uploadId: expiredAlbumUploadId, takenAt: Date.now() },
    });
    const albumItemsResponse = await app.inject({
      method: "GET",
      url: `/api/v2/albums/${signedAlbumId}/items?limit=10`,
      headers: { authorization },
    });
    const albumItemsBody = albumItemsResponse.json() as {
      album?: { coverURL?: string };
      items?: Array<{ asset?: { url?: string } }>;
    };
    const refreshedAssetURL = new URL(albumItemsBody.items?.[0]?.asset?.url ?? "https://invalid.local");
    const refreshedCoverURL = new URL(albumItemsBody.album?.coverURL ?? "https://invalid.local");
    assertOk(
      "共同相册读取会刷新过期的封面与视频签名",
      albumCreateResponse.statusCode === 201 &&
        albumAddResponse.statusCode === 201 &&
        albumItemsResponse.statusCode === 200 &&
        refreshedAssetURL.pathname === `/media/${expiredAlbumUploadId}` &&
        refreshedCoverURL.pathname === `/media/${expiredAlbumUploadId}` &&
        Number(refreshedAssetURL.searchParams.get("exp") ?? "0") > Date.now() &&
        Number(refreshedCoverURL.searchParams.get("exp") ?? "0") > Date.now(),
    );

    const cardAccountId = currentUser!.accountId!;
    const cardFixtures = [
      ["smoke-card-massage", cardAccountId, "intimacy_massage", "rare"],
      ["smoke-card-add-time", cardAccountId, "support_add_time", "common"],
      ["smoke-card-postpone", cardAccountId, "support_postpone", "common"],
      ["smoke-card-copy", cardAccountId, "support_copy", "common"],
      ["smoke-card-copy-source", partnerUser!.accountId!, "money_red_packet", "rare"],
      ["smoke-card-qiankun", partnerUser!.accountId!, "support_qiankun", "common"],
    ] as const;
    for (const [id, accountId, cardKey, rarity] of cardFixtures) {
      await db.run(
        `INSERT INTO card_game_inventory
         (id, account_id, card_key, rarity, quantity, created_at, updated_at)
         VALUES (?, ?, ?, ?, 1, ?, ?)`,
        [id, accountId, cardKey, rarity, now, now],
      );
    }
    const cardSnapshotResponse = await app.inject({
      method: "GET", url: "/api/v2/card-game", headers: { authorization },
    });
    const cardSnapshotBody = cardSnapshotResponse.json() as {
      ok?: boolean;
      game?: { drawsRemaining?: number; inventory?: Array<{ cardKey: string }> };
    };
    assertOk(
      "情侣卡牌快照返回每日次数与个人卡库",
      cardSnapshotResponse.statusCode === 200 &&
        cardSnapshotBody.ok === true &&
        cardSnapshotBody.game?.drawsRemaining === 3 &&
        cardSnapshotBody.game.inventory?.some((item) => item.cardKey === "intimacy_massage") === true,
    );
    const cardUseResponse = await app.inject({
      method: "POST",
      url: "/api/v2/card-game/use",
      headers: { authorization },
      payload: {
        cardKey: "intimacy_massage",
        rarity: "rare",
        idempotencyKey: "smoke-card-use-1",
      },
    });
    const cardUseBody = cardUseResponse.json() as {
      ok?: boolean;
      effect?: { id?: string; expiresAt?: number | null };
      game?: { inventory?: Array<{ cardKey: string }> };
    };
    const cardUseEffectID = cardUseBody.effect?.id;
    assertOk(
      "情侣卡牌使用一次即扣库存并开始倒计时",
      cardUseResponse.statusCode === 200 &&
        cardUseBody.ok === true &&
        typeof cardUseEffectID === "string" &&
        (cardUseBody.effect?.expiresAt ?? 0) > now &&
        !cardUseBody.game?.inventory?.some((item) => item.cardKey === "intimacy_massage"),
    );
    const initialExpiry = cardUseBody.effect?.expiresAt ?? 0;
    const addTimeResponse = await app.inject({
      method: "POST",
      url: "/api/v2/card-game/use",
      headers: { authorization },
      payload: {
        cardKey: "support_add_time",
        rarity: "common",
        idempotencyKey: "smoke-card-add-time-1",
        effectId: cardUseEffectID,
      },
    });
    const addTimeBody = addTimeResponse.json() as {
      game?: {
        activeEffects?: Array<{ id: string; startsAt: number; expiresAt: number | null }>;
        inventory?: Array<{ cardKey: string }>;
      };
    };
    const extendedEffect = addTimeBody.game?.activeEffects?.find((effect) => effect.id === cardUseEffectID);
    assertOk(
      "加时卡增加指定倒计时并消耗一次",
      addTimeResponse.statusCode === 200 &&
        extendedEffect?.expiresAt === initialExpiry + 5 * 60_000 &&
        !addTimeBody.game?.inventory?.some((item) => item.cardKey === "support_add_time"),
    );
    const postponeResponse = await app.inject({
      method: "POST",
      url: "/api/v2/card-game/use",
      headers: { authorization },
      payload: {
        cardKey: "support_postpone",
        rarity: "common",
        idempotencyKey: "smoke-card-postpone-1",
        effectId: cardUseEffectID,
      },
    });
    const postponeBody = postponeResponse.json() as {
      game?: {
        activeEffects?: Array<{ id: string; startsAt: number; expiresAt: number | null; status: string }>;
        inventory?: Array<{ cardKey: string }>;
      };
    };
    const postponedEffect = postponeBody.game?.activeEffects?.find((effect) => effect.id === cardUseEffectID);
    assertOk(
      "延期卡延后开始与结束时间并消耗一次",
      postponeResponse.statusCode === 200 &&
        postponedEffect?.startsAt === (extendedEffect?.startsAt ?? 0) + 24 * 60 * 60_000 &&
        postponedEffect?.expiresAt === (extendedEffect?.expiresAt ?? 0) + 24 * 60 * 60_000 &&
        postponedEffect?.status === "pending" &&
        !postponeBody.game?.inventory?.some((item) => item.cardKey === "support_postpone"),
    );
    const copyResponse = await app.inject({
      method: "POST",
      url: "/api/v2/card-game/use",
      headers: { authorization },
      payload: {
        cardKey: "support_copy",
        rarity: "common",
        idempotencyKey: "smoke-card-copy-1",
        sourceCardKey: "money_red_packet",
        sourceRarity: "rare",
      },
    });
    const copyBody = copyResponse.json() as {
      game?: {
        inventory?: Array<{ cardKey: string; rarity: string }>;
        partnerInventory?: Array<{ cardKey: string; rarity: string }>;
      };
    };
    assertOk(
      "复制卡复制对方卡片且不扣对方库存",
      copyResponse.statusCode === 200 &&
        copyBody.game?.inventory?.some((item) =>
          item.cardKey === "money_red_packet" && item.rarity === "rare") === true &&
        copyBody.game?.partnerInventory?.some((item) =>
          item.cardKey === "money_red_packet" && item.rarity === "rare") === true &&
        !copyBody.game?.inventory?.some((item) => item.cardKey === "support_copy"),
    );
    const qiankunResponse = await app.inject({
      method: "POST",
      url: "/api/v2/card-game/use",
      headers: { authorization: partnerAuthorization },
      payload: {
        cardKey: "support_qiankun",
        rarity: "common",
        idempotencyKey: "smoke-card-qiankun-1",
        effectId: cardUseEffectID,
      },
    });
    const qiankunBody = qiankunResponse.json() as {
      game?: {
        activeEffects?: Array<{ id: string; targetUsername: string }>;
        inventory?: Array<{ cardKey: string }>;
      };
    };
    assertOk(
      "乾坤大挪移把对己效果转回对方并消耗一次",
      qiankunResponse.statusCode === 200 &&
        qiankunBody.game?.activeEffects?.find((effect) => effect.id === cardUseEffectID)
          ?.targetUsername === currentUser!.username &&
        !qiankunBody.game?.inventory?.some((item) => item.cardKey === "support_qiankun"),
    );
    const cardUseReplay = await app.inject({
      method: "POST",
      url: "/api/v2/card-game/use",
      headers: { authorization },
      payload: {
        cardKey: "intimacy_massage",
        rarity: "rare",
        idempotencyKey: "smoke-card-use-1",
      },
    });
    assertOk(
      "情侣卡牌使用幂等不会重复创建效果",
      cardUseReplay.statusCode === 200 && cardUseReplay.json().effect?.id === cardUseEffectID,
    );
    const drawResponses = await Promise.all(
      [1, 2, 3].map((index) => app.inject({
        method: "POST",
        url: "/api/v2/card-game/draw",
        headers: { authorization },
        payload: { idempotencyKey: "smoke-card-draw-" + index },
      })),
    );
    const fourthDraw = await app.inject({
      method: "POST",
      url: "/api/v2/card-game/draw",
      headers: { authorization },
      payload: { idempotencyKey: "smoke-card-draw-4" },
    });
    assertOk(
      "情侣卡牌每天最多三次抽卡",
      drawResponses.every((response) => response.statusCode === 200) && fourthDraw.statusCode === 429,
    );
    const oldAuthorization = await app.inject({
      method: "GET", url: "/api/me", headers: { authorization: `Bearer ${createToken(user)}` },
    });
    assertOk("旧无设备 token 被拒绝", oldAuthorization.statusCode === 401);
    const healthResponse = await app.inject({ method: "GET", url: "/health" });
    const liveResponse = await app.inject({ method: "GET", url: "/live" });
    const readyResponse = await app.inject({ method: "GET", url: "/ready" });
    const mcpGetResponse = await app.inject({ method: "GET", url: "/api/ai-mcp" });
    const bootstrapResponse = await app.inject({
      method: "GET", url: "/api/bootstrap", headers: { authorization },
    });
    const messagePageResponse = await app.inject({
      method: "GET", url: "/api/messages?channel=couple&limit=20", headers: { authorization },
    });
    const referencedMessageResponse = await app.inject({
      method: "GET",
      url: `/api/messages/${encodeURIComponent(referenced!.id)}?channel=couple`,
      headers: { authorization },
    });
    const wrongChannelReferenceResponse = await app.inject({
      method: "GET",
      url: `/api/messages/${encodeURIComponent(referenced!.id)}?channel=ai`,
      headers: { authorization },
    });
    const retiredOnThisDayResponse = await app.inject({
      method: "GET",
      url: "/api/v2/media/on-this-day?timezone=Asia%2FShanghai",
      headers: { authorization },
    });
    const signedResponse = await app.inject({ method: "GET", url: new URL(routeMediaURL).pathname + new URL(routeMediaURL).search });
    const thumbnailResponse = await app.inject({
      method: "GET",
      url: new URL(routeThumbnailURL).pathname + new URL(routeThumbnailURL).search,
    });
    const thumbnailRangeResponse = await app.inject({
      method: "GET",
      url: new URL(routeThumbnailURL).pathname + new URL(routeThumbnailURL).search,
      headers: { range: "bytes=1-4" },
    });
    const rangeResponse = await app.inject({
      method: "GET",
      url: new URL(routeMediaURL).pathname + new URL(routeMediaURL).search,
      headers: { range: "bytes=2-7" },
    });
    const invalidRangeResponse = await app.inject({
      method: "GET",
      url: new URL(routeMediaURL).pathname + new URL(routeMediaURL).search,
      headers: { range: "bytes=99-120" },
    });
    const multipleRangeResponse = await app.inject({
      method: "GET",
      url: new URL(routeMediaURL).pathname + new URL(routeMediaURL).search,
      headers: { range: "bytes=0-1,4-5" },
    });
    const compatibleRouteResponse = await app.inject({ method: "GET", url: `/uploads/${compatibleRouteFilename}` });
    const invalidSignatureResponse = await app.inject({ method: "GET", url: `/media/${routeMediaId}?sig=invalid-signature-value-000000000000` });
    const bypassResponse = await app.inject({ method: "GET", url: `/uploads/${path.basename(routeMediaPath)}` });
    const clientOriginal = await sharp({
      create: {
        width: 1_400,
        height: 900,
        channels: 3,
        background: { r: 84, g: 142, b: 235 },
      },
    }).jpeg().toBuffer();
    const clientThumbnail = await sharp(clientOriginal)
      .resize({ width: 720, height: 720, fit: "inside" })
      .jpeg({ quality: 78 })
      .toBuffer();
    const uploadBoundary = "SmokeBoundaryClientThumbnail";
    const uploadPayload = Buffer.concat([
      Buffer.from(
        `--${uploadBoundary}\r\n` +
        "Content-Disposition: form-data; name=\"thumbnailBase64\"\r\n" +
        "Content-Type: text/plain; charset=us-ascii\r\n\r\n",
      ),
      Buffer.from(clientThumbnail.toString("base64")),
      Buffer.from(
        `\r\n--${uploadBoundary}\r\n` +
        "Content-Disposition: form-data; name=\"file\"; filename=\"client-original.jpg\"\r\n" +
        "Content-Type: image/jpeg\r\n\r\n",
      ),
      clientOriginal,
      Buffer.from(`\r\n--${uploadBoundary}--\r\n`),
    ]);
    const uploadResponse = await app.inject({
      method: "POST",
      url: "/api/upload?purpose=message",
      headers: {
        authorization,
        "content-type": `multipart/form-data; boundary=${uploadBoundary}`,
      },
      payload: uploadPayload,
    });
    const uploadedBody = uploadResponse.statusCode === 200
      ? uploadResponse.json<{ id: string }>()
      : undefined;
    const uploadedRow = uploadedBody
      ? await db.get<{ path: string }>("SELECT path FROM uploads WHERE id = ?", [uploadedBody.id])
      : undefined;
    const uploadedThumbnailPath = uploadedRow ? thumbnailPathFor(uploadedRow.path) : undefined;
    const invalidThumbnailPayload = Buffer.concat([
      Buffer.from(
        `--${uploadBoundary}\r\n` +
        "Content-Disposition: form-data; name=\"thumbnailBase64\"\r\n" +
        "Content-Type: text/plain; charset=us-ascii\r\n\r\n" +
        `${clientOriginal.toString("base64")}\r\n` +
        `--${uploadBoundary}\r\n` +
        "Content-Disposition: form-data; name=\"file\"; filename=\"client-original.jpg\"\r\n" +
        "Content-Type: image/jpeg\r\n\r\n",
      ),
      clientOriginal,
      Buffer.from(`\r\n--${uploadBoundary}--\r\n`),
    ]);
    const invalidThumbnailResponse = await app.inject({
      method: "POST",
      url: "/api/upload?purpose=message",
      headers: {
        authorization,
        "content-type": `multipart/form-data; boundary=${uploadBoundary}`,
      },
      payload: invalidThumbnailPayload,
    });
    const invalidAvatarBoundary = "SmokeBoundaryInvalidAvatar";
    const invalidAvatarPayload = Buffer.from(
      `--${invalidAvatarBoundary}\r\n` +
      "Content-Disposition: form-data; name=\"file\"; filename=\"avatar.pdf\"\r\n" +
      "Content-Type: application/pdf\r\n\r\n" +
      "%PDF-smoke\r\n" +
      `--${invalidAvatarBoundary}--\r\n`,
    );
    const invalidAvatarResponse = await app.inject({
      method: "POST",
      url: "/api/upload?purpose=avatar",
      headers: {
        authorization,
        "content-type": `multipart/form-data; boundary=${invalidAvatarBoundary}`,
      },
      payload: invalidAvatarPayload,
    });
    await app.close();
    assertOk(
      "REST bootstrap 与消息分页返回有界快照",
      bootstrapResponse.statusCode === 200 &&
        bootstrapResponse.json().messages.couple.length <= 40 &&
        messagePageResponse.statusCode === 200 &&
        messagePageResponse.json().list.length <= 20 &&
        typeof messagePageResponse.json().total === "number",
    );
    assertOk(
      "REST 引用消息查询按当前会话隔离",
      referencedMessageResponse.statusCode === 200 &&
        referencedMessageResponse.json().message.id === referenced!.id &&
        wrongChannelReferenceResponse.statusCode === 404,
    );
    assertOk("那年今日接口已完整退役", retiredOnThisDayResponse.statusCode === 404);
    assertOk("AI MCP GET 探测继续保持 405 契约", mcpGetResponse.statusCode === 405);
    assertOk(
      "上传接口校验并保留客户端生成的 JPEG 缩略图",
      uploadResponse.statusCode === 200 &&
        invalidThumbnailResponse.statusCode === 415 &&
        invalidAvatarResponse.statusCode === 415 &&
        uploadedThumbnailPath !== undefined &&
        fs.existsSync(uploadedThumbnailPath) &&
        fs.readFileSync(uploadedThumbnailPath).equals(clientThumbnail),
    );
    assertOk(
      "签名原图/缩略图支持 Range 且拒绝伪造签名和裸路径旁路",
      healthResponse.statusCode === 200 && healthResponse.json().database === "ok" &&
        liveResponse.statusCode === 200 && liveResponse.json().process === "alive" &&
        readyResponse.statusCode === 200 && readyResponse.json().database === "ok" &&
        signedResponse.statusCode === 200 && signedResponse.body === "signed-media" &&
        thumbnailResponse.statusCode === 200 && thumbnailResponse.body === "signed-thumb" &&
        thumbnailResponse.headers["content-type"] === "image/jpeg" &&
        thumbnailRangeResponse.statusCode === 206 && thumbnailRangeResponse.body === "igne" &&
        thumbnailRangeResponse.headers["content-range"] === "bytes 1-4/12" &&
        rangeResponse.statusCode === 206 && rangeResponse.body === "gned-m" &&
        rangeResponse.headers["accept-ranges"] === "bytes" &&
        rangeResponse.headers["content-range"] === "bytes 2-7/12" &&
        invalidRangeResponse.statusCode === 416 && invalidRangeResponse.body === "" &&
        invalidRangeResponse.headers["content-range"] === "bytes */12" &&
        multipleRangeResponse.statusCode === 416 && multipleRangeResponse.body === "" &&
        multipleRangeResponse.headers["content-range"] === "bytes */12" &&
        compatibleRouteResponse.statusCode === 200 && compatibleRouteResponse.body === "compatible-media" &&
        invalidSignatureResponse.statusCode === 404 && bypassResponse.statusCode === 404,
    );

    // 已读回执只能前进到当前 conversation 中真实存在的最后一条消息。
    const latestCoupleMessage = await db.get<{ ts: number }>(
      "SELECT MAX(ts) AS ts FROM messages WHERE conversation_id = ?",
      ["conv_legacy_couple"],
    );
    await upsertReadReceipt(user, "couple", created.ts);
    await upsertReadReceipt(user, "couple", created.ts - 5);
    await upsertReadReceipt(user, "couple", created.ts + 5_000);
    const receipts = await getReadReceipts(user, "couple");
    assertOk(
      "read_receipts 单调更新且不会越过最后消息",
      receipts[user.username] === latestCoupleMessage?.ts,
    );

    // shared kv
    const { setSharedItem, getSharedState } = await import("../src/shared/sharedService");
    await setSharedItem(user, "smoke", { hello: "pg" });
    await setSharedItem(user, "smoke", { hello: "pg2" });
    const shared = await getSharedState(user);
    assertOk(
      "shared_items upsert",
      (shared.smoke?.value as { hello?: string })?.hello === "pg2",
    );

    // personal items CRUD
    const items = await import("../src/personalItems/itemService");
    const item = await items.createPersonalItem(user, { kind: "reminder", title: "冒烟提醒", dueAt: Date.now() + 60000 });
    assertOk("createPersonalItem", Boolean(item?.id));
    const patched = await items.updatePersonalItem(user, item!.id, { isDone: true });
    assertOk(
      "updatePersonalItem isDone",
      Boolean(patched) && !("conflict" in patched!) && patched!.isDone === true,
    );

    // 乐观并发：baseVersion 过期必须返回冲突而不是静默覆盖；提醒备忘此前是唯一
    // 没有冲突保护的数据，两台设备同时编辑会直接覆盖对方。
    const fresh = await items.getPersonalItem(user, item!.id);
    const staleUpdate = await items.updatePersonalItem(user, item!.id, {
      title: "并发覆盖尝试",
      baseVersion: (fresh!.version ?? 0) - 1,
    });
    const freshUpdate = await items.updatePersonalItem(user, item!.id, {
      title: "按当前版本更新",
      baseVersion: fresh!.version ?? 0,
    });
    assertOk(
      "提醒备忘按 baseVersion 拒绝过期写入，按当前版本正常更新",
      Boolean(staleUpdate) && "conflict" in staleUpdate!
        && Boolean(freshUpdate) && !("conflict" in freshUpdate!)
        && freshUpdate!.title === "按当前版本更新",
    );
    assertOk("deletePersonalItem", await items.deletePersonalItem(user, item!.id));

    // AI 确认卡取消必须通过 ACK 返回最终 meta，不能只依赖可能丢失的广播。
    const confirmationMeta = {
      confirm: {
        status: "pending" as const,
        items: [{
          label: "备忘：冒烟备忘",
          action: { type: "add_memo" as const, title: "冒烟备忘", text: "不会真正写入" },
        }],
        requesterName: user.name,
        requesterUsername: user.username,
      },
    };
    await db.run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, ts, meta_json, conversation_id)
       VALUES (?, 'couple', 'ai', '大橘', 'user', 'text', ?, ?, ?, 'conv_legacy_couple')`,
      ["smoke-confirm-cancel", "确认卡", now + 1, JSON.stringify(confirmationMeta)],
    );
    const confirmationBroadcasts: Array<{ room: string; event: string; payload: unknown }> = [];
    const fakeIO = {
      to: (room: string) => ({
        emit: (event: string, payload: unknown) => {
          confirmationBroadcasts.push({ room, event, payload });
        },
      }),
    } as unknown as Server;
    const {
      confirmAction,
      recoverInterruptedConfirmations,
    } = await import("../src/ai/actions/personalItems");
    const cancelledConfirmation = await confirmAction(
      fakeIO,
      user,
      "smoke-confirm-cancel",
      "cancel",
    );
    const storedConfirmation = await db.get<{ status: string }>(
      `SELECT meta_json::jsonb #>> '{confirm,status}' AS status FROM messages WHERE id = ?`,
      ["smoke-confirm-cancel"],
    );
    assertOk(
      "AI 备忘确认卡取消 ACK 返回最终状态并广播",
      cancelledConfirmation.ok &&
        cancelledConfirmation.messageId === "smoke-confirm-cancel" &&
        cancelledConfirmation.meta.confirm.status === "cancelled" &&
        storedConfirmation?.status === "cancelled" &&
        confirmationBroadcasts.some((event) =>
          event.room === "couple:cpl_legacy_xusi" && event.event === "message:update"),
    );

    const interruptedConfirmationMeta: ConfirmMeta = {
      confirm: {
        status: "processing" as const,
        items: [
          {
            label: "已记录成功的动作",
            action: { type: "add_memo" as const, title: "已执行动作" },
            result: "succeeded" as const,
          },
          {
            label: "不能在重启后重放",
            action: {
              type: "add_memo" as const,
              title: "绝不能被恢复任务创建",
              text: "恢复只能失败收敛",
            },
          },
        ],
        requesterName: user.name,
        requesterUsername: user.username,
      },
    };
    await db.run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, ts, meta_json, conversation_id)
       VALUES (?, 'couple', 'ai', '大橘', 'user', 'text', ?, ?, ?, 'conv_legacy_couple')`,
      [
        "smoke-confirm-interrupted",
        "中断确认卡",
        now + 2,
        JSON.stringify(interruptedConfirmationMeta),
      ],
    );
    const itemsBeforeRecovery = await db.get<{ count: number }>(
      "SELECT COUNT(*)::int AS count FROM personal_items WHERE title = ?",
      ["绝不能被恢复任务创建"],
    );
    const recoveredConfirmationCount = await recoverInterruptedConfirmations();
    const recoveredAgainCount = await recoverInterruptedConfirmations();
    const recoveredConfirmationRow = await db.get<{ meta_json: string }>(
      "SELECT meta_json FROM messages WHERE id = ?",
      ["smoke-confirm-interrupted"],
    );
    const recoveredConfirmation = JSON.parse(
      recoveredConfirmationRow?.meta_json ?? "{}",
    ) as ConfirmMeta;
    const itemsAfterRecovery = await db.get<{ count: number }>(
      "SELECT COUNT(*)::int AS count FROM personal_items WHERE title = ?",
      ["绝不能被恢复任务创建"],
    );
    assertOk(
      "启动恢复把 processing confirmation 安全收敛且不重放动作",
      recoveredConfirmationCount === 1
        && recoveredAgainCount === 0
        && recoveredConfirmation.confirm.status === "confirmed"
        && recoveredConfirmation.confirm.failed === 1
        && recoveredConfirmation.confirm.items[0]?.result === "succeeded"
        && recoveredConfirmation.confirm.items[1]?.result === "failed"
        && recoveredConfirmation.confirm.items[1]?.error === "execution_failed"
        && itemsBeforeRecovery?.count === 0
        && itemsAfterRecovery?.count === 0,
    );

    const runtimeState = await import("../src/ai/runtimeState");
    await runtimeState.writeRuntimeState("smoke", "ok");
    assertOk("AI 运行状态读写", (await runtimeState.readRuntimeState("smoke")) === "ok");

    const {
      CONTEXT_DIGEST_CIRCUIT_COOLDOWN_MS,
      applyDigestPatch,
      ensureContextCaughtUp,
      isContextDigestCircuitOpen,
      nextContextDigestCircuitState,
    } = await import("../src/ai/conversation/context");
    const circuitNow = 10_000_000;
    const circuitAfterOneFailure = nextContextDigestCircuitState(
      { failures: 0, openUntil: 0 },
      false,
      circuitNow,
    );
    const circuitAfterTwoFailures = nextContextDigestCircuitState(
      circuitAfterOneFailure,
      false,
      circuitNow + 1,
    );
    const recoveredCircuit = nextContextDigestCircuitState(
      circuitAfterTwoFailures,
      true,
      circuitNow + CONTEXT_DIGEST_CIRCUIT_COOLDOWN_MS + 2,
    );
    assertOk(
      "上下文日总览连续失败后熔断，成功探测后恢复",
      !isContextDigestCircuitOpen(circuitAfterOneFailure, circuitNow) &&
        isContextDigestCircuitOpen(circuitAfterTwoFailures, circuitNow + 2) &&
        !isContextDigestCircuitOpen(
          circuitAfterTwoFailures,
          circuitNow + CONTEXT_DIGEST_CIRCUIT_COOLDOWN_MS + 2,
        ) &&
        recoveredCircuit.failures === 0 &&
        recoveredCircuit.openUntil === 0,
    );
    const patchedDigest = applyDigestPatch({
      dayKey: "2026-07-18",
      topics: [{
        id: "topic_trip",
        title: "周末出行",
        status: "open",
        actors: ["both"],
        points: ["正在比较路线"],
        lastAt: circuitNow - 1_000,
      }],
      decisions: [],
      openLoops: ["决定是否订票"],
      moodLine: "",
      updatedAt: circuitNow - 1_000,
    }, {
      topics: [{
        matchId: "topic_trip",
        title: "周末出行",
        status: "done",
        actors: ["both"],
        points: ["已经买好车票"],
      }],
      decisionsAdd: ["决定坐高铁"],
      openLoopsClose: ["决定是否订票"],
      moodLine: "安排已经落定",
    }, circuitNow);
    assertOk(
      "上下文日总览补丁复用话题并增量关闭未决事项",
      patchedDigest?.digest.topics.length === 1 &&
        patchedDigest.digest.topics[0].id === "topic_trip" &&
        patchedDigest.digest.topics[0].status === "done" &&
        patchedDigest.digest.topics[0].points.includes("已经买好车票") &&
        patchedDigest.digest.decisions.includes("决定坐高铁") &&
        patchedDigest.digest.openLoops.length === 0 &&
        patchedDigest.digest.moodLine === "安排已经落定",
    );

    const { addDays, cycleBounds, cycleDate } = await import("../src/ai/time");
    const crossDayChannel = "ai:smoke-cross-day";
    const currentContextDay = cycleDate();
    const previousContextDay = addDays(currentContextDay, -1);
    const oldestContextDay = addDays(currentContextDay, -2);
    const oldestContextStart = cycleBounds(oldestContextDay).start;
    const previousContextStart = cycleBounds(previousContextDay).start;
    const currentContextStart = cycleBounds(currentContextDay).start;
    await runtimeState.writeRuntimeState(`context:v2:${crossDayChannel}`, JSON.stringify({
      strategy: "day-digest-v2",
      rawCursor: { ts: oldestContextStart, id: "" },
      dayKey: oldestContextDay,
      dayDigest: {
        dayKey: oldestContextDay,
        topics: [],
        decisions: [],
        openLoops: [],
        moodLine: "",
        updatedAt: oldestContextStart,
      },
      recentSegments: [],
      pendingSegments: [],
    }));
    await db.run(
      `INSERT INTO messages
       (id, channel, sender, sender_name, kind, type, text, ts, sender_account_id)
       VALUES
       (?, ?, 'xu', '小旭', 'user', 'text', '跨日第一天未整理消息', ?, 'acc_legacy_xu'),
       (?, ?, 'si', '小偲', 'user', 'text', '跨日第二天未整理消息', ?, 'acc_legacy_si'),
       (?, ?, 'xu', '小旭', 'user', 'text', '跨日今天未整理消息', ?, 'acc_legacy_xu')`,
      [
        "smoke-context-day-1", crossDayChannel, oldestContextStart + 60_000,
        "smoke-context-day-2", crossDayChannel, previousContextStart + 60_000,
        "smoke-context-day-3", crossDayChannel, currentContextStart + 60_000,
      ],
    );
    const crossDayCatchUp = await ensureContextCaughtUp(
      crossDayChannel,
      { force: true, budgetMs: 30_000 },
    );
    const crossDayStateRaw = await runtimeState.readRuntimeState(`context:v2:${crossDayChannel}`);
    const crossDayState = JSON.parse(crossDayStateRaw) as {
      dayKey?: string;
      rawCursor?: { ts?: number; id?: string };
    };
    assertOk(
      "Context 跨多日追赶先消费旧消息，不会把 rawCursor 直接跳到今天",
      !crossDayCatchUp.incomplete &&
        crossDayCatchUp.lagMessageCount === 0 &&
        crossDayState.dayKey === currentContextDay &&
        crossDayState.rawCursor?.id === "smoke-context-day-3",
    );

    const {
      ENGAGEMENT_CONFLICT_GLOBAL_OVERRIDE,
      ENGAGEMENT_MAX_SEGMENT_AGE_MS,
      engagementCooldownBlock,
      isEngagementSegmentStale,
      localEngagementGate,
    } = await import("../src/ai/engagement");
    const engagementDigest = {
      dayKey: "2026-07-18",
      topics: [],
      openLoops: ["明天记得订票"],
      decisions: [],
      moodLine: "早些时候有争执",
    };
    const cooldownNow = 20_000_000;
    const engagementSegment = (bullets: string[]) => ({
      id: "seg_smoke",
      dayKey: "2026-07-18",
      timeRangeLabel: "17:00–17:10",
      endedAt: cooldownNow,
      messageCount: 12,
      bullets,
    });
    assertOk(
      "主动搭话只看当前线索，冲突按先后缓和并受跨类型冷却保护",
      localEngagementGate(
        engagementDigest,
        engagementSegment(["两人正在安静看电影"]),
        ["刚聊到电影剧情"],
      ) === "skip" &&
        localEngagementGate(
          engagementDigest,
          engagementSegment(["之前说了抱抱"]),
          ["随后又说你太过分了"],
        ) === "run" &&
        localEngagementGate(
          engagementDigest,
          engagementSegment(["刚才争执得很厉害"]),
          ["现在已经和好了"],
        ) === "skip" &&
        localEngagementGate(
          engagementDigest,
          engagementSegment(["周末去哪，选哪个还没决定"]),
          [],
        ) === "run" &&
        engagementCooldownBlock(
          "conflict",
          ENGAGEMENT_CONFLICT_GLOBAL_OVERRIDE - 0.01,
          cooldownNow,
          { global: cooldownNow - 1_000 },
        )?.scope === "global" &&
        engagementCooldownBlock(
          "conflict",
          ENGAGEMENT_CONFLICT_GLOBAL_OVERRIDE,
          cooldownNow,
          { global: cooldownNow - 1_000 },
        ) === null &&
        engagementCooldownBlock(
          "interject",
          1,
          cooldownNow,
          { interject: cooldownNow - 1_000, global: cooldownNow - 1_000 },
        )?.scope === "kind" &&
        !isEngagementSegmentStale(cooldownNow, cooldownNow) &&
        isEngagementSegmentStale(
          cooldownNow - ENGAGEMENT_MAX_SEGMENT_AGE_MS - 1,
          cooldownNow,
        ),
    );

    const { rankChatSearchRows, searchTerms } = await import("../src/ai/conversation/search");
    const searchRow = (id: string, text: string, ts: number) => ({
      id, channel: "couple", sender: user.username, sender_name: user.name, kind: "user", type: "text",
      text, url: null, reply_json: null, meta_json: null, attachments_json: null, recalled_text: null, ts, client_id: null,
    });
    const expandedSearch = rankChatSearchRows([
      searchRow("search-alternative-content", "使用替代表述记录了答案", 200),
      searchRow("search-subject", "甲方正在讨论另一个话题", 100),
    ], ["甲方", "核心主题", "替代表述"], "all", 5);
    assertOk(
      "原文搜索使用 Agent alternatives 发散并统一重排",
      searchTerms("核心 主题").includes("主题") &&
        expandedSearch.relaxed &&
        expandedSearch.hits.some((hit) => hit.row.id === "search-alternative-content"),
    );

    const tiedTs = Date.now() + 10_000;
    await db.run(
      `INSERT INTO messages (id, channel, sender, sender_name, kind, type, text, ts)
       VALUES (?, 'couple', ?, ?, 'user', 'text', '游标 A', ?),
              (?, 'couple', ?, ?, 'user', 'text', '游标 B', ?)`,
      ["cursor-smoke-a", user.username, user.name, tiedTs, "cursor-smoke-b", user.username, user.name, tiedTs],
    );
    const { messagesAfter, ownerTextMessagesAfter } = await import("../src/ai/conversation/log");
    const tiedMessages = await messagesAfter("couple", { ts: tiedTs, id: "cursor-smoke-a" }, 10);
    const ownerTiedMessages = await ownerTextMessagesAfter("couple", { ts: tiedTs, id: "cursor-smoke-a" }, 30);
    const {
      MEMORY_SOURCE_BATCH_SIZE,
      MEMORY_EVENT_EVIDENCE_THRESHOLD,
      memoryExtractionDelay,
      memoryEventEvidenceScore,
      shouldExtractMemoryBatch,
      shouldAdvanceMemoryCursorForBatch,
      shouldRecoverMemoryEvent,
      shouldRetryEmptyMemoryBatch,
    } = await import("../src/ai/memory/extractor");
    const completedMilestoneScore = memoryEventEvidenceScore([
      "我已经把表格和图制作完成，并通过微信发给你了",
    ]);
    const futurePlanScore = memoryEventEvidenceScore([
      "我计划明天把表格做完，晚点发给你",
    ]);
    assertOk(
      "Memory 按80条硬上限整理，并只对明确完成节点补做 event 复核",
      MEMORY_SOURCE_BATCH_SIZE === 80 &&
        !shouldExtractMemoryBatch(79) && shouldExtractMemoryBatch(80) && shouldExtractMemoryBatch(1, true) &&
        memoryExtractionDelay(20, tiedTs, tiedTs, tiedTs) === 15 * 60 * 1000 &&
        !shouldRetryEmptyMemoryBatch(11, 0) &&
        shouldRetryEmptyMemoryBatch(12, 0) &&
        !shouldRetryEmptyMemoryBatch(80, 1) &&
        completedMilestoneScore >= MEMORY_EVENT_EVIDENCE_THRESHOLD &&
        futurePlanScore === 0 &&
        !shouldRecoverMemoryEvent(11, completedMilestoneScore, false) &&
        shouldRecoverMemoryEvent(12, completedMilestoneScore, false) &&
        !shouldRecoverMemoryEvent(80, completedMilestoneScore, true) &&
        tiedMessages.some((message) => message.id === "cursor-smoke-b") &&
        !tiedMessages.some((message) => message.id === "cursor-smoke-a") &&
        ownerTiedMessages.some((message) => message.id === "cursor-smoke-b"),
    );
    assertOk(
      "Memory 无候选可推进、全拒绝必须保留游标、至少保存一项才推进",
      shouldAdvanceMemoryCursorForBatch(0, 0) &&
        !shouldAdvanceMemoryCursorForBatch(3, 0) &&
        shouldAdvanceMemoryCursorForBatch(3, 1),
    );

    const memory = await import("../src/ai/memory/store");
    const dajuInstructionXu = await memory.addMemory({
      layer: "fact",
      perspective: "daju",
      kind: "instruction",
      scope: "couple",
      memoryKey: "instruction.smoke.xu",
      subjects: [user.username],
      speakers: [user.username],
      content: "只对当前测试主人使用简短回答",
      category: "大橘行为要求",
      confidence: 1,
      importance: 5,
    });
    const dajuInstructionPartner = await memory.addMemory({
      layer: "fact",
      perspective: "daju",
      kind: "instruction",
      scope: "couple",
      memoryKey: "instruction.smoke.partner",
      subjects: [partnerAccount.username],
      speakers: [partnerAccount.username],
      content: "只对另一位主人使用详细回答",
      category: "大橘行为要求",
      confidence: 1,
      importance: 5,
    });
    const dajuInstructionBoth = await memory.addMemory({
      layer: "fact",
      perspective: "daju",
      kind: "instruction",
      scope: "couple",
      memoryKey: "instruction.smoke.both",
      subjects: ["both"],
      speakers: [user.username],
      content: "对两位主人都保持事实准确",
      category: "大橘行为要求",
      confidence: 1,
      importance: 5,
    });
    const {
      listDajuInstructionsForRequester,
    } = await import("../src/ai/memory/dajuInstructions");
    const xuDajuInstructions = await listDajuInstructionsForRequester(
      "couple",
      user.username,
    );
    const partnerDajuInstructions = await listDajuInstructionsForRequester(
      "couple",
      partnerAccount.username,
    );
    assertOk(
      "大橘预注入与 MCP 指令读取按 requester 隔离并共享 both",
      xuDajuInstructions.some((item) => item.id === dajuInstructionXu?.id)
        && xuDajuInstructions.some((item) => item.id === dajuInstructionBoth?.id)
        && !xuDajuInstructions.some((item) => item.id === dajuInstructionPartner?.id)
        && partnerDajuInstructions.some((item) => item.id === dajuInstructionPartner?.id)
        && partnerDajuInstructions.some((item) => item.id === dajuInstructionBoth?.id)
        && !partnerDajuInstructions.some((item) => item.id === dajuInstructionXu?.id),
    );
    const firstMemory = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "preference.smoke.color",
      subjects: [user.username], speakers: [user.username], content: "喜欢蓝色",
      category: "preference", confidence: 0.9, importance: 3,
    });
    const nextMemory = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "preference.smoke.color",
      subjects: [user.username], speakers: [user.username], content: "现在更喜欢绿色",
      category: "preference", confidence: 0.95, importance: 3,
    });
    const memoryResults = await memory.searchMemory({
      query: "", layers: ["fact"], scopes: ["couple"], subjects: [user.username], limit: 20,
    });
    const previousMemory = await db.get<{ status: string }>("SELECT status FROM ai_memory WHERE id = ?", [firstMemory!.id]);
    const evidence = await db.get<{ count: number }>(
      "SELECT COUNT(*)::int AS count FROM ai_memory_evidence WHERE memory_id = ?",
      [nextMemory!.id],
    );
    assertOk(
      "Memory 同 key 版本替代且不保存原始消息证据",
      previousMemory?.status === "superseded" &&
        memoryResults.some((item) => item.id === nextMemory!.id && item.content === "现在更喜欢绿色") &&
        evidence?.count === 0,
    );
    const systemSyncedMemory = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "fact.smoke.system_sync",
      subjects: [user.username], speakers: [], content: "后台整理写入同步测试",
      category: "test", confidence: 0.9, importance: 2,
    }, { actorAccountId: null });
    const systemMemorySync = await db.get<{ entity_type: string; operation: string }>(
      `SELECT entity_type, operation FROM sync_events
       WHERE entity_type = 'memory' AND entity_id = ? ORDER BY seq DESC LIMIT 1`,
      [systemSyncedMemory!.id],
    );
    assertOk(
      "后台 Memory 写入生成 Sync V2 事件",
      Boolean(systemSyncedMemory?.version)
        && systemMemorySync?.entity_type === "memory"
        && systemMemorySync.operation === "upsert",
    );
    const correctedMemory = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "model.generated.different.key",
      subjects: [user.username], speakers: [user.username], content: "现在最喜欢黄色",
      category: "preference", confidence: 0.96, importance: 3,
      targetMemoryId: nextMemory!.id,
    });
    const replacedTarget = await db.get<{ status: string }>("SELECT status FROM ai_memory WHERE id = ?", [nextMemory!.id]);
    assertOk(
      "Memory 定向更新复用目标 key，不依赖模型再次生成相同 key",
      correctedMemory?.memoryKey === nextMemory?.memoryKey && replacedTarget?.status === "superseded",
    );
    const eventInput = {
      layer: "event" as const, scope: "couple", memoryKey: "health.smoke.medication",
      subjects: [user.username], speakers: [user.username], content: "服用了测试药物",
      category: "health", confidence: 0.95, importance: 4,
      occurredAt: created.ts,
    };
    const firstEvent = await memory.addMemory(eventInput);
    const repeatedEvent = await memory.addMemory(eventInput);
    const eventKey = firstEvent?.memoryKey ?? "";
    const duplicateEventCount = await db.get<{ count: number }>(
      `SELECT COUNT(*)::int AS count FROM ai_memory
       WHERE layer = 'event' AND scope = 'couple' AND memory_key = ? AND content = ?`,
      [eventKey, eventInput.content],
    );
    assertOk(
      "Memory 同一原文事件重复抽取保持幂等",
      Boolean(firstEvent?.id)
        && firstEvent?.id === repeatedEvent?.id
        && firstEvent?.memoryKey === repeatedEvent?.memoryKey
        && duplicateEventCount?.count === 1,
    );
    const temporaryState = await memory.addMemory({
      layer: "state", scope: "couple", memoryKey: "state.smoke.temporary",
      subjects: [user.username], speakers: [user.username], content: "暂时很困",
      category: "mood", confidence: 0.9, importance: 2,
      validFrom: Date.now() - 1000, validUntil: Date.now() - 1,
    });
    await memory.expireMemoryStates();
    const activeStates = await memory.searchMemory({ query: "", layers: ["state"], scopes: ["couple"] });
    assertOk(
      "Memory 状态 TTL 自动失效",
      Boolean(temporaryState?.id)
        && !activeStates.some((item) => item.id === temporaryState!.id),
    );

    const plan = await memory.addMemory({
      layer: "plan", scope: "couple", memoryKey: "plan.smoke.trip",
      subjects: [user.username], speakers: [user.username], content: "准备完成测试行程",
      category: "plan", confidence: 0.9, importance: 3,
    });
    const completed = await memory.transitionMemory({
      memoryId: plan!.id, scope: "couple", status: "completed",
      reason: "主人明确表示已经完成",
    });
    const completedPlan = await db.get<{ status: string }>("SELECT status FROM ai_memory WHERE id = ?", [plan!.id]);
    assertOk("Memory 计划支持完成/取消生命周期", completed && completedPlan?.status === "completed");

    const editorAccount = await db.get<{ id: string }>(
      "SELECT id FROM accounts WHERE username = ?",
      [user.username],
    );
    const rollingStateInput = {
      layer: "state" as const,
      scope: "couple",
      memoryKey: "state.smoke.rolling",
      subjects: [user.username],
      speakers: [user.username],
      content: "最近正在专注准备冒烟测试",
      category: "state",
      confidence: 0.9,
      importance: 3,
    };
    const rollingState = await memory.addMemory(rollingStateInput);
    const rollingDeleted = await memory.deleteMemoryForControl({
      memoryId: rollingState!.id,
      scopes: ["couple"],
      coupleId: "cpl_legacy_xusi",
      editorAccountId: editorAccount!.id,
    });
    const exactRollingRecreated = await memory.addMemory(rollingStateInput);
    await db.run(
      `INSERT INTO ai_memory_exclusions
       (id, couple_id, account_id, memory_key, source_message_id, created_by_account_id, created_at)
       VALUES (?, 'cpl_legacy_xusi', NULL, ?, NULL, ?, ?)
       ON CONFLICT DO NOTHING`,
      [
        "mex_smoke_legacy_rolling",
        rollingState!.memoryKey,
        editorAccount!.id,
        Date.now(),
      ],
    );
    const changedRollingState = await memory.addMemory({
      ...rollingStateInput,
      content: "最近已经完成冒烟测试并开始复核结果",
    });
    const expectedRollingExclusionKey = memory.memoryExclusionKey(
      rollingStateInput.layer,
      rollingState!.memoryKey,
      rollingStateInput.content,
    );
    const rollingExclusion = await db.get<{ memory_key: string }>(
      `SELECT memory_key FROM ai_memory_exclusions
        WHERE couple_id = 'cpl_legacy_xusi' AND memory_key = ?
        LIMIT 1`,
      [expectedRollingExclusionKey],
    );
    assertOk(
      "删除 rolling Memory 只屏蔽被删内容，不会永久禁用固定滚动 key",
      rollingDeleted &&
        exactRollingRecreated === null &&
        Boolean(changedRollingState?.id) &&
        rollingExclusion?.memory_key === expectedRollingExclusionKey,
    );

    // 固定层（fact/event/plan）曾经按裸 memory_key 排除，导致"忘掉一条"= 该主题
    // 永久写不进来。排除项现在一律带内容指纹，这条守住的就是那个回归。
    const stableFactInput = {
      layer: "fact" as const,
      scope: "couple",
      memoryKey: "fact.smoke.exclusion_scope",
      subjects: [user.username],
      speakers: [user.username],
      content: "冒烟测试用的可替换事实：偏好 A",
      category: "test",
      confidence: 0.9,
      importance: 3,
    };
    const stableFact = await memory.addMemory(stableFactInput);
    const stableFactDeleted = await memory.deleteMemoryForControl({
      memoryId: stableFact!.id,
      scopes: ["couple"],
      coupleId: "cpl_legacy_xusi",
      editorAccountId: editorAccount!.id,
    });
    const sameStableFact = await memory.addMemory(stableFactInput);
    const newerStableFact = await memory.addMemory({
      ...stableFactInput,
      content: "冒烟测试用的可替换事实：偏好 B",
    });
    assertOk(
      "忘掉固定层 Memory 只屏蔽被删内容，同一个 key 仍可写入新信息",
      stableFactDeleted &&
        sameStableFact === null &&
        Boolean(newerStableFact?.id),
    );

    const dependencyBaseA = await memory.addMemory({
      layer: "fact",
      scope: "couple",
      memoryKey: "fact.smoke.dependency_a",
      subjects: [user.username],
      speakers: [user.username],
      content: "派生删除测试的第一条基础事实",
      category: "test",
      confidence: 0.95,
      importance: 3,
    });
    const dependencyBaseB = await memory.addMemory({
      layer: "event",
      scope: "couple",
      memoryKey: "event.smoke.dependency_b",
      subjects: ["both"],
      speakers: [user.username],
      content: "两个人共同完成了派生删除冒烟测试",
      category: "test",
      confidence: 0.95,
      importance: 3,
      occurredAt: Date.now(),
    });
    const dependentRelationship = await memory.addMemory({
      layer: "relationship",
      scope: "couple",
      memoryKey: "relationship.smoke.dependencies",
      subjects: ["both"],
      speakers: [],
      content: "两个人会一起完成测试并认真复核结果",
      category: "test",
      confidence: 0.85,
      importance: 3,
      sourceMemoryIds: [dependencyBaseA!.id, dependencyBaseB!.id],
    }, { actorAccountId: null });
    const dependencyDeleted = await memory.deleteMemoryForControl({
      memoryId: dependencyBaseA!.id,
      scopes: ["couple"],
      coupleId: "cpl_legacy_xusi",
      editorAccountId: editorAccount!.id,
    });
    const remainingDependent = await db.get<{ id: string }>(
      "SELECT id FROM ai_memory WHERE id = ?",
      [dependentRelationship!.id],
    );
    const dependentDeleteSync = await db.get<{ operation: string }>(
      `SELECT operation FROM sync_events
        WHERE entity_type = 'memory' AND entity_id = ?
        ORDER BY seq DESC LIMIT 1`,
      [dependentRelationship!.id],
    );
    assertOk(
      "删除基础 Memory 会级联删除含该内容的派生卡并发送 Sync delete",
      dependencyDeleted &&
        !remainingDependent &&
        dependentDeleteSync?.operation === "delete",
    );

    const inactiveSourceDerived = await memory.addMemory({
      layer: "insight",
      scope: "couple",
      memoryKey: "insight.smoke.inactive_source",
      subjects: ["both"],
      speakers: [],
      content: "不应从已经完成的计划继续形成洞察",
      category: "test",
      confidence: 0.8,
      importance: 2,
      sourceMemoryIds: [plan!.id],
    });
    const lifecyclePlan = await memory.addMemory({
      layer: "plan",
      scope: "couple",
      memoryKey: "plan.smoke.derived_lifecycle",
      subjects: ["both"],
      speakers: [user.username],
      content: "准备验证派生卡的来源状态传播",
      category: "test",
      confidence: 0.9,
      importance: 3,
    });
    const lifecycleInsight = await memory.addMemory({
      layer: "insight",
      scope: "couple",
      memoryKey: "insight.smoke.lifecycle",
      subjects: ["both"],
      speakers: [],
      content: "当前正在共同验证来源状态传播",
      category: "test",
      confidence: 0.8,
      importance: 2,
      sourceMemoryIds: [lifecyclePlan!.id],
    });
    await memory.transitionMemory({
      memoryId: lifecyclePlan!.id,
      scope: "couple",
      status: "completed",
      reason: "冒烟验证完成",
    });
    await memory.reconcileMemoryLifecycle();
    const reconciledInsight = await db.get<{ status: string }>(
      "SELECT status FROM ai_memory WHERE id = ?",
      [lifecycleInsight!.id],
    );
    const reconciledInsightSync = await db.get<{ operation: string }>(
      `SELECT operation FROM sync_events
        WHERE entity_type = 'memory' AND entity_id = ?
        ORDER BY seq DESC LIMIT 1`,
      [lifecycleInsight!.id],
    );
    assertOk(
      "派生 Memory 只接受 active 来源，来源完成后现有派生卡失效并同步删除",
      inactiveSourceDerived === null &&
        reconciledInsight?.status === "retracted" &&
        reconciledInsightSync?.operation === "delete",
    );

    const recallEvidence = await createMessage(user, {
      channel: "couple", type: "text", text: "这是一条即将撤回的记忆证据", clientId: "smoke-memory-recall",
    });
    const recallBoundMemory = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "fact.smoke.recall",
      subjects: [user.username], speakers: [user.username], content: "临时撤回测试事实",
      category: "test", confidence: 0.9, importance: 2,
    });
    await recallMessage(user, recallEvidence.id);
    const invalidatedMemory = await db.get<{ status: string }>(
      "SELECT status FROM ai_memory WHERE id = ?",
      [recallBoundMemory!.id],
    );
    assertOk("主人撤回原消息不会删除独立 Memory 卡", invalidatedMemory?.status === "active");
    stopMemoryEvents();

    console.log("[5/5] 清理…");
    await db.closeDatabase();
  } finally {
    // 嵌入式 PG / 连接池偶发 stop 挂起；限时清理后靠 process.exit 收尾。
    await Promise.race([
      (async () => {
        await closeDatabase?.().catch(() => undefined);
        await pg.stop().catch(() => undefined);
        fs.rmSync(dataDir, { recursive: true, force: true });
      })(),
      new Promise<void>((resolve) => setTimeout(resolve, 8_000)),
    ]);
  }
  console.log(failureCount > 0 ? `冒烟测试有 ${failureCount} 个失败项 ✗` : "冒烟测试全部通过 ✓");
  if (failureCount > 0) throw new Error(`冒烟测试有 ${failureCount} 个失败项`);
  // 冒烟会拉起 Fastify / 定时器 / 嵌入式 PG；显式退出避免 Node 事件循环挂住卡死 publish。
  process.exit(0);
}

main().catch((error) => {
  console.error("冒烟测试失败:", error);
  process.exit(1);
});
