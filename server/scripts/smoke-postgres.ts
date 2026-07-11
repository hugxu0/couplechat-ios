// PostgreSQL 日常冒烟测试：启动临时数据库，建表并跑代表性业务读写路径。
// 用法（server/ 下）：npx tsx scripts/smoke-postgres.ts

import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import EmbeddedPostgres from "embedded-postgres";

const PORT = 5544;
const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "couplechat-pg-"));

async function main() {
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

  try {
    // 动态 import：确保 config 读到上面设置的 DATABASE_URL
    const db = await import("../src/db");
    console.log("[2/5] 建表…");
    await db.initDatabase();

    console.log("[3/5] 写入测试夹具…");
    const now = Date.now();
    await db.run(
      `INSERT INTO accounts (username, display_name, password_hash, avatar, created_at, updated_at)
       VALUES (?, ?, ?, '', ?, ?), (?, ?, ?, '', ?, ?)`,
      ["xu", "小旭", "smoke-hash", now, now, "si", "小偲", "smoke-hash", now, now],
    );
    for (let index = 0; index < 120; index += 1) {
      const sender = index % 2 === 0 ? "xu" : "si";
      await db.run(
        `INSERT INTO messages
         (id, channel, sender, sender_name, kind, type, text, ts)
         VALUES (?, 'couple', ?, ?, 'user', 'text', ?, ?)`,
        [
          `smoke-source-${index}`,
          sender,
          sender === "xu" ? "小旭" : "小偲",
          index % 7 === 0 ? `第 ${index} 条喵消息` : `第 ${index} 条测试消息`,
          now - (120 - index) * 60_000,
        ],
      );
    }

    console.log("[4/5] 服务层冒烟…");
    const assertOk = (label: string, cond: boolean) => {
      console.log(`  ${cond ? "✓" : "✗"} ${label}`);
      if (!cond) process.exitCode = 1;
    };

    const migrations = await db.all<{ version: number; name: string }>(
      "SELECT version, name FROM schema_migrations ORDER BY version ASC",
    );
    assertOk(
      "数据库结构版本完整",
      migrations.length === 10 &&
        migrations[0].version === 1 && migrations[0].name === "initial_schema" &&
        migrations[1].version === 2 && migrations[1].name === "bind_uploads_to_messages" &&
        migrations[2].version === 3 && migrations[2].name === "classify_upload_purpose" &&
        migrations[3].version === 4 && migrations[3].name === "preserve_recalled_text" &&
        migrations[4].version === 5 && migrations[4].name === "message_attachments" &&
        migrations[5].version === 6 && migrations[5].name === "memory_v2" &&
        migrations[6].version === 7 && migrations[6].name === "canonical_memory_names" &&
        migrations[7].version === 8 && migrations[7].name === "ensure_ai_runtime_state" &&
        migrations[8].version === 9 && migrations[8].name === "memory_import_staging" &&
        migrations[9].version === 10 && migrations[9].name === "memory_cursor_tie_breaker",
    );

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

    // AI 可靠性：超时必须发兜底；队列过载必须保留最新请求而不是静默丢弃。
    const { ReplyQueue, runReplyTaskWithTimeout } = await import("../src/ai/agent/replyQueue");
    const aiTrigger = {
      storedChannel: "ai:smoke",
      question: "测试",
      requesterName: "测试用户",
      requesterUsername: "smoke",
    };
    const timeoutReplies: string[] = [];
    const timeoutSink = {
      emit: async (_channel: string, text: string) => { timeoutReplies.push(text); },
      typing: () => undefined,
      replying: () => undefined,
    };
    await runReplyTaskWithTimeout(
      aiTrigger,
      timeoutSink,
      async () => new Promise<void>(() => undefined),
      5,
    );
    assertOk("AI 超时会发送兜底回复", timeoutReplies.length === 1);
    const backgroundTimeoutReplies: string[] = [];
    await runReplyTaskWithTimeout(
      { ...aiTrigger, origin: "conflict" },
      { ...timeoutSink, emit: async (_channel, value) => { backgroundTimeoutReplies.push(value); } },
      async () => new Promise<void>(() => undefined),
      5,
    );
    assertOk("后台介入 Agent 超时保持沉默", backgroundTimeoutReplies.length === 0);

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
    const { listPublicAccounts, authenticate } = await import("../src/auth/accounts");
    const accounts = await listPublicAccounts();
    assertOk(`listPublicAccounts → ${accounts.length} 个账号`, accounts.length === 2);

    // 消息：分页 / since / after+before / around / 搜索 / LIKE
    const { fetchMessages, searchMessages, createMessage, recallMessage, upsertReadReceipt, getReadReceipts } = await import("../src/chat/messageService");
    const user = { username: accounts[0].username, name: accounts[0].name };
    const latest = await fetchMessages(user, { channel: "couple", limit: 50 });
    assertOk(`fetchMessages latest → ${latest.length} 条`, latest.length === 50);
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
    assertOk(`searchMessages "喵" → ${found.length} 条`, found.length > 0);

    // 写入一条新消息（含 reply/meta JSON + clientId 幂等）
    const created = await createMessage(user, { channel: "couple", type: "text", text: "PG 冒烟测试", clientId: "smoke-1" });
    const dup = await createMessage(user, { channel: "couple", type: "text", text: "PG 冒烟测试重复", clientId: "smoke-1" });
    assertOk("clientId 幂等（重发返回同一条）", created.id === dup.id);

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
    const recalledUpload = await db.get<{ id: string }>("SELECT id FROM uploads WHERE id = ?", [uploadId]);
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
    const remainingAlbumUploads = await db.all<{ id: string }>(
      "SELECT id FROM uploads WHERE id IN (?, ?)", [albumPhotoId, albumMotionId],
    );
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

    const { signedMediaURL, signMediaId, verifyMediaSignature } = await import("../src/upload/mediaAccess");
    const signedURL = new URL(signedMediaURL("up_signature_123"));
    const signature = signedURL.searchParams.get("sig") ?? "";
    assertOk(
      "新媒体 URL 使用 HMAC 签名",
      signedURL.pathname === "/media/up_signature_123" &&
        signature === signMediaId("up_signature_123") &&
        verifyMediaSignature("up_signature_123", signature) &&
        !verifyMediaSignature("up_signature_456", signature),
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
    const { buildApp } = await import("../src/app");
    const { createToken } = await import("../src/auth/token");
    const app = await buildApp();
    const authorization = `Bearer ${createToken(user)}`;
    const healthResponse = await app.inject({ method: "GET", url: "/health" });
    const bootstrapResponse = await app.inject({
      method: "GET", url: "/api/bootstrap", headers: { authorization },
    });
    const messagePageResponse = await app.inject({
      method: "GET", url: "/api/messages?channel=couple&limit=20", headers: { authorization },
    });
    const signedResponse = await app.inject({ method: "GET", url: new URL(routeMediaURL).pathname + new URL(routeMediaURL).search });
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
      "签名媒体路由拒绝伪造签名和裸路径旁路",
      healthResponse.statusCode === 200 && healthResponse.json().database === "ok" &&
        signedResponse.statusCode === 200 && signedResponse.body === "signed-media" &&
        compatibleRouteResponse.statusCode === 200 && compatibleRouteResponse.body === "compatible-media" &&
        invalidSignatureResponse.statusCode === 404 && bypassResponse.statusCode === 404,
    );

    // 已读回执 upsert
    await upsertReadReceipt(user, "couple", created.ts);
    await upsertReadReceipt(user, "couple", created.ts + 5);
    const receipts = await getReadReceipts(user, "couple");
    assertOk("read_receipts ON CONFLICT 更新", receipts[user.username] === created.ts + 5);

    // shared kv
    const { setSharedItem, getSharedState } = await import("../src/shared/sharedService");
    await setSharedItem(user, "smoke", { hello: "pg" });
    await setSharedItem(user, "smoke", { hello: "pg2" });
    const shared = await getSharedState();
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
    const { MEMORY_SOURCE_BATCH_SIZE, shouldExtractMemoryBatch } = await import("../src/ai/memory/extractor");
    assertOk(
      "Memory 按30条主人文字分批且使用 (ts,id) 游标",
      MEMORY_SOURCE_BATCH_SIZE === 30 &&
        !shouldExtractMemoryBatch(29) && shouldExtractMemoryBatch(30) && shouldExtractMemoryBatch(1, true) &&
        tiedMessages.some((message) => message.id === "cursor-smoke-b") &&
        !tiedMessages.some((message) => message.id === "cursor-smoke-a") &&
        ownerTiedMessages.some((message) => message.id === "cursor-smoke-b"),
    );

    const memory = await import("../src/ai/memory/store");
    const firstMemory = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "preference.smoke.color",
      subjects: [user.username], speakers: [user.username], content: "喜欢蓝色",
      category: "preference", confidence: 0.9, importance: 3, sourceMessageIds: [created.id],
    });
    const nextMemory = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "preference.smoke.color",
      subjects: [user.username], speakers: [user.username], content: "现在更喜欢绿色",
      category: "preference", confidence: 0.95, importance: 3, sourceMessageIds: [created.id],
    });
    const memoryResults = await memory.searchMemory({
      query: "", layers: ["fact"], scopes: ["couple"], subjects: [user.username], limit: 20,
    });
    const previousMemory = await db.get<{ status: string }>("SELECT status FROM ai_memory WHERE id = ?", [firstMemory!.id]);
    const evidence = await memory.memoryEvidence(nextMemory!.id, ["couple"]);
    assertOk(
      "Memory 同 key 版本替代并保留主人原文证据",
      previousMemory?.status === "superseded" &&
        memoryResults.some((item) => item.id === nextMemory!.id && item.content === "现在更喜欢绿色") &&
        evidence.some((item) => item.message_id === created.id),
    );
    const correctedMemory = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "model.generated.different.key",
      subjects: [user.username], speakers: [user.username], content: "现在最喜欢黄色",
      category: "preference", confidence: 0.96, importance: 3, sourceMessageIds: [created.id],
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
      occurredAt: created.ts, sourceMessageIds: [created.id],
    };
    const firstEvent = await memory.addMemory(eventInput);
    const repeatedEvent = await memory.addMemory(eventInput);
    const duplicateEventCount = await db.get<{ count: number }>(
      `SELECT COUNT(*)::int AS count FROM ai_memory
       WHERE layer = 'event' AND scope = 'couple' AND memory_key = ? AND content = ?`,
      [eventInput.memoryKey, eventInput.content],
    );
    assertOk(
      "Memory 同一原文事件重复抽取保持幂等",
      firstEvent?.id === repeatedEvent?.id && duplicateEventCount?.count === 1,
    );
    await memory.addMemory({
      layer: "state", scope: "couple", memoryKey: "state.smoke.temporary",
      subjects: [user.username], speakers: [user.username], content: "暂时很困",
      category: "mood", confidence: 0.9, importance: 2,
      validFrom: Date.now() - 1000, validUntil: Date.now() - 1, sourceMessageIds: [created.id],
    });
    await memory.expireMemoryStates();
    const activeStates = await memory.searchMemory({ query: "", layers: ["state"], scopes: ["couple"] });
    assertOk("Memory 状态 TTL 自动失效", !activeStates.some((item) => item.memoryKey === "state.smoke.temporary"));

    const plan = await memory.addMemory({
      layer: "plan", scope: "couple", memoryKey: "plan.smoke.trip",
      subjects: [user.username], speakers: [user.username], content: "准备完成测试行程",
      category: "plan", confidence: 0.9, importance: 3, sourceMessageIds: [created.id],
    });
    const completed = await memory.transitionMemory({
      memoryId: plan!.id, scope: "couple", status: "completed",
      sourceMessageIds: [created.id], reason: "主人明确表示已经完成",
    });
    const completedPlan = await db.get<{ status: string }>("SELECT status FROM ai_memory WHERE id = ?", [plan!.id]);
    assertOk("Memory 计划支持完成/取消生命周期", completed && completedPlan?.status === "completed");

    const { minimumEvidenceForLayer } = await import("../src/ai/memory/extractor");
    assertOk("Memory 洞察强制至少三条新消息证据", minimumEvidenceForLayer("insight") === 3);

    const recallEvidence = await createMessage(user, {
      channel: "couple", type: "text", text: "这是一条即将撤回的记忆证据", clientId: "smoke-memory-recall",
    });
    const recallBoundMemory = await memory.addMemory({
      layer: "fact", scope: "couple", memoryKey: "fact.smoke.recall",
      subjects: [user.username], speakers: [user.username], content: "临时撤回测试事实",
      category: "test", confidence: 0.9, importance: 2, sourceMessageIds: [recallEvidence.id],
    });
    await recallMessage(user, recallEvidence.id);
    const invalidatedMemory = await db.get<{ status: string }>(
      "SELECT status FROM ai_memory WHERE id = ?",
      [recallBoundMemory!.id],
    );
    assertOk("主人撤回原消息会传播到 Memory 证据链", invalidatedMemory?.status === "retracted");

    console.log("[5/5] 清理…");
    await db.closeDatabase();
  } finally {
    await pg.stop();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
  console.log(process.exitCode ? "冒烟测试有失败项 ✗" : "冒烟测试全部通过 ✓");
}

main().catch((error) => {
  console.error("冒烟测试失败:", error);
  process.exit(1);
});
