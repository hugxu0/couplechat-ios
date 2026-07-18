// PostgreSQL 日常冒烟测试：启动临时数据库，建表并跑代表性业务读写路径。
// 用法（server/ 下）：npx tsx scripts/smoke-postgres.ts

import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import EmbeddedPostgres from "embedded-postgres";

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

  let closeDatabase: (() => Promise<void>) | undefined;
  try {
    // 动态 import：确保 config 读到上面设置的 DATABASE_URL
    const db = await import("../src/db");
    closeDatabase = db.closeDatabase;
    console.log("[2/5] 建表…");
    await db.initDatabase();

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
    ] as const;
    assertOk(
      "数据库结构版本完整",
      migrations.length === expectedMigrations.length &&
        migrations.every((migration, index) =>
          migration.version === expectedMigrations[index][0] && migration.name === expectedMigrations[index][1]),
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

    // 账号
    const { listPublicAccounts } = await import("../src/auth/accounts");
    const accounts = await listPublicAccounts();
    assertOk(`listPublicAccounts → ${accounts.length} 个账号`, accounts.length === 2);

    // 消息：分页 / since / after+before / around / 搜索 / LIKE
    const { subscribeMemoryDomainEvents } = await import("../src/ai/memory/events");
    const stopMemoryEvents = subscribeMemoryDomainEvents();
    const { fetchMessageById, fetchMessages, searchMessages, createMessage, recallMessage, upsertReadReceipt, getReadReceipts } = await import("../src/chat/messageService");
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
    fs.writeFileSync(mediaPath, "media");
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
    const recalledMedia = await recallMessage(user, media.id);
    let recalledUpload = await db.get<{ id: string }>("SELECT id FROM uploads WHERE id = ?", [uploadId]);
    for (let attempt = 0; attempt < 50 && (recalledUpload || fs.existsSync(mediaPath)); attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
      recalledUpload = await db.get<{ id: string }>("SELECT id FROM uploads WHERE id = ?", [uploadId]);
    }
    assertOk(
      "撤回媒体消息同时删除附件",
      recalledMedia?.id === media.id && !recalledUpload && !fs.existsSync(mediaPath),
    );

    // 相册/Live Photo：一条逻辑消息原子绑定静态图与 paired video，撤回整组清理。
    const albumPhotoId = "up_smoke_album_photo";
    const albumMotionId = "up_smoke_album_motion";
    const albumPhotoPath = path.join(dataDir, "smoke-album.jpg");
    const albumMotionPath = path.join(dataDir, "smoke-album.mov");
    fs.writeFileSync(albumPhotoPath, "photo");
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
      attempt < 50 && (remainingAlbumUploads.length > 0 || fs.existsSync(albumPhotoPath) || fs.existsSync(albumMotionPath));
      attempt += 1
    ) {
      await new Promise((resolve) => setTimeout(resolve, 10));
      remainingAlbumUploads = await db.all<{ id: string }>(
        "SELECT id FROM uploads WHERE id IN (?, ?)", [albumPhotoId, albumMotionId],
      );
    }
    assertOk(
      "撤回相册消息清理整组附件",
      remainingAlbumUploads.length === 0 && !fs.existsSync(albumPhotoPath) && !fs.existsSync(albumMotionPath),
    );
    // 只清理明确用于消息且超过 24h 仍未绑定的文件；头像/贴纸不误删。
    const abandonedPath = path.join(dataDir, "abandoned-message.jpg");
    const avatarPath = path.join(dataDir, "keep-avatar.jpg");
    fs.writeFileSync(abandonedPath, "abandoned");
    fs.writeFileSync(avatarPath, "avatar");
    const oldCreatedAt = Date.now() - 2 * 24 * 60 * 60 * 1000;
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      ["up_abandoned_123", user.username, abandonedPath, "https://example.com/abandoned.jpg", "image/jpeg", 9, oldCreatedAt, "message"],
    );
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      ["up_avatar_keep_123", user.username, avatarPath, "https://example.com/avatar.jpg", "image/jpeg", 6, oldCreatedAt, "avatar"],
    );
    const { cleanupAbandonedMessageUploads } = await import("../src/upload/cleanup");
    const cleaned = await cleanupAbandonedMessageUploads();
    const keptAvatar = await db.get<{ id: string }>("SELECT id FROM uploads WHERE id = ?", ["up_avatar_keep_123"]);
    assertOk(
      "过期消息附件清理且不误删头像",
      cleaned === 1 && !fs.existsSync(abandonedPath) && fs.existsSync(avatarPath) && keptAvatar?.id === "up_avatar_keep_123",
    );

    const { signedMediaURL, signMediaId, verifyMediaSignature, parseRequestedByteRange } = await import("../src/upload/mediaAccess");
    const signedURL = new URL(signedMediaURL("up_signature_123"));
    const signature = signedURL.searchParams.get("sig") ?? "";
    const exp = Number(signedURL.searchParams.get("exp") ?? "0");
    const signed = signMediaId("up_signature_123", exp);
    assertOk(
      "新媒体 URL 使用 HMAC 签名与过期时间",
      signedURL.pathname === "/media/up_signature_123" &&
        Number.isFinite(exp) && exp > Date.now() &&
        signature === signed.sig &&
        verifyMediaSignature("up_signature_123", signature, exp) &&
        !verifyMediaSignature("up_signature_456", signature, exp) &&
        !verifyMediaSignature("up_signature_123", signature, Date.now() - 1_000),
    );
    const suffixRange = parseRequestedByteRange("bytes=-500", 10_000);
    assertOk(
      "媒体 suffix Range 指向文件尾部（支持视频分段读取）",
      suffixRange?.start === 9_500 && suffixRange.end === 9_999,
    );
    const routeMediaId = "up_signed_route_123";
    const routeMediaPath = path.join(dataDir, `${routeMediaId}.txt`);
    fs.writeFileSync(routeMediaPath, "signed-media");
    const routeMediaURL = signedMediaURL(routeMediaId);
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [routeMediaId, user.username, routeMediaPath, routeMediaURL, "text/plain", 12, Date.now(), "avatar"],
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
    assertOk("当前登录生成设备绑定 session", Boolean(currentUser?.sessionId && currentUser.deviceId));
    const { buildApp } = await import("../src/app");
    const app = await buildApp();
    const authorization = `Bearer ${createToken(currentUser!)}`;
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
    const rangeResponse = await app.inject({
      method: "GET",
      url: new URL(routeMediaURL).pathname + new URL(routeMediaURL).search,
      headers: { range: "bytes=2-7" },
    });
    const compatibleRouteResponse = await app.inject({ method: "GET", url: `/uploads/${compatibleRouteFilename}` });
    const invalidSignatureResponse = await app.inject({ method: "GET", url: `/media/${routeMediaId}?sig=invalid-signature-value-000000000000` });
    const bypassResponse = await app.inject({ method: "GET", url: `/uploads/${path.basename(routeMediaPath)}` });
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
      "签名媒体路由拒绝伪造签名和裸路径旁路",
      healthResponse.statusCode === 200 && healthResponse.json().database === "ok" &&
        liveResponse.statusCode === 200 && liveResponse.json().process === "alive" &&
        readyResponse.statusCode === 200 && readyResponse.json().database === "ok" &&
        signedResponse.statusCode === 200 && signedResponse.body === "signed-media" &&
        rangeResponse.statusCode === 206 && rangeResponse.body === "gned-m" &&
        rangeResponse.headers["accept-ranges"] === "bytes" &&
        rangeResponse.headers["content-range"] === "bytes 2-7/12" &&
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
    assertOk("updatePersonalItem isDone", patched?.isDone === true);
    assertOk("deletePersonalItem", await items.deletePersonalItem(user, item!.id));

    const runtimeState = await import("../src/ai/runtimeState");
    await runtimeState.writeRuntimeState("smoke", "ok");
    assertOk("AI 运行状态读写", (await runtimeState.readRuntimeState("smoke")) === "ok");

    const {
      CONTEXT_DIGEST_CIRCUIT_COOLDOWN_MS,
      applyDigestPatch,
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

    const memory = await import("../src/ai/memory/store");
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
