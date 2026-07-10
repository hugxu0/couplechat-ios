// PostgreSQL 冒烟测试：起一个内嵌 PG → 建表 → 从 .data/couplechat.sqlite 全量迁移 →
// 跑一遍代表性读写路径，验证 SQL 方言/占位符转换/BYTEA/BIGINT 解析都正确。
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

  try {
    // 动态 import：确保 config 读到上面设置的 DATABASE_URL
    const db = await import("../src/db");
    console.log("[2/5] 建表…");
    await db.initDatabase();

    console.log("[3/5] 迁移 SQLite 数据…");
    const { DatabaseSync } = await import("node:sqlite");
    const sqlite = new DatabaseSync(path.resolve(".data/couplechat.sqlite"), { readOnly: true });

    const tables: Array<{ name: string; columns: string[] }> = [
      { name: "accounts", columns: ["username", "display_name", "password_hash", "avatar", "bark_key", "created_at", "updated_at"] },
      { name: "messages", columns: ["id", "channel", "sender", "sender_name", "kind", "type", "text", "url", "reply_json", "meta_json", "ts", "client_id"] },
      { name: "read_receipts", columns: ["channel", "username", "ts", "updated_at"] },
      { name: "shared_items", columns: ["key", "value_json", "updated_by", "updated_at"] },
      { name: "personal_items", columns: ["id", "owner", "kind", "scope", "title", "body_markdown", "due_at", "is_done", "created_at", "updated_at"] },
      { name: "uploads", columns: ["id", "owner", "path", "url", "mime_type", "size", "created_at"] },
      { name: "ai_facts", columns: ["id", "subject", "category", "text", "importance", "status", "embedding", "created_at", "updated_at", "last_seen_at"] },
      { name: "ai_episodes", columns: ["id", "channel", "date", "title", "summary", "key_points_json", "mood", "conclusion", "keywords", "embedding", "created_at"] },
      { name: "ai_docs", columns: ["key", "text", "updated_at"] },
    ];
    for (const t of tables) {
      const rows = sqlite.prepare(`SELECT ${t.columns.map((c) => `"${c}"`).join(",")} FROM "${t.name}"`).all() as Record<string, unknown>[];
      for (let i = 0; i < rows.length; i += 500) {
        const chunk = rows.slice(i, i + 500);
        const values = chunk.map(() => `(${t.columns.map(() => "?").join(",")})`).join(",");
        await db.run(
          `INSERT INTO ${t.name} (${t.columns.join(",")}) VALUES ${values} ON CONFLICT DO NOTHING`,
          chunk.flatMap((r) => t.columns.map((c) => r[c] ?? null)),
        );
      }
      console.log(`  ${t.name}: ${rows.length} 行`);
    }
    sqlite.close();

    console.log("[4/5] 服务层冒烟…");
    const assertOk = (label: string, cond: boolean) => {
      console.log(`  ${cond ? "✓" : "✗"} ${label}`);
      if (!cond) process.exitCode = 1;
    };

    const migrations = await db.all<{ version: number; name: string }>(
      "SELECT version, name FROM schema_migrations ORDER BY version ASC",
    );
    assertOk(
      "schema_migrations 记录全部迁移",
      migrations.length === 3 &&
        migrations[0].version === 1 && migrations[0].name === "initial_schema" &&
        migrations[1].version === 2 && migrations[1].name === "bind_uploads_to_messages" &&
        migrations[2].version === 3 && migrations[2].name === "classify_upload_purpose",
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
    const { ReplyQueue, runReplyTaskWithTimeout } = await import("../src/ai/replyEngine");
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

    const { hasTaskIntentHint } = await import("../src/ai/intent");
    assertOk(
      "AI 任务意图在分类模型失败时仍可确定",
      hasTaskIntentHint("十分钟后提醒我吃药")
        && hasTaskIntentHint("把购物清单记到备忘录")
        && hasTaskIntentHint("明早喊我起床")
        && !hasTaskIntentHint("今晚吃什么好"),
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
    const legacyRouteFilename = "1783639852451-95c29e3767ff.jpg";
    const legacyRoutePath = path.join(dataDir, legacyRouteFilename);
    fs.writeFileSync(legacyRoutePath, "legacy-media");
    await db.run(
      "INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [
        "legacy_route_timestamp_hash", user.username, legacyRoutePath,
        `https://example.com/uploads/${legacyRouteFilename}`, "image/jpeg", 12, Date.now(), "legacy",
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
    const legacyRouteResponse = await app.inject({ method: "GET", url: `/uploads/${legacyRouteFilename}` });
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
        legacyRouteResponse.statusCode === 200 && legacyRouteResponse.body === "legacy-media" &&
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
    assertOk("shared_items upsert", (shared.smoke?.value as { hello?: string })?.hello === "pg2");

    // personal items CRUD
    const items = await import("../src/personalItems/itemService");
    const item = await items.createPersonalItem(user, { kind: "reminder", title: "冒烟提醒", dueAt: Date.now() + 60000 });
    assertOk("createPersonalItem", Boolean(item?.id));
    const patched = await items.updatePersonalItem(user, item!.id, { isDone: true });
    assertOk("updatePersonalItem isDone", patched?.isDone === true);
    assertOk("deletePersonalItem", await items.deletePersonalItem(user, item!.id));

    // AI 记忆：embedding BYTEA 读回 + 向量解包
    const { listFacts, getDoc, setDoc, listEpisodes } = await import("../src/ai/memoryStore");
    const facts = await listFacts({ limit: 2000 });
    const withVector = facts.filter((f) => f.vector && f.vector.length > 0);
    assertOk(`ai_facts → ${facts.length} 条（${withVector.length} 条带向量）`, facts.length === 95 && withVector.length > 0);
    const episodes = await listEpisodes("couple");
    assertOk(`ai_episodes(couple) → ${episodes.length} 张卡`, episodes.length > 0);
    await setDoc("smoke-doc", "hello");
    await setDoc("smoke-doc", "hello2");
    assertOk("ai_docs upsert", (await getDoc("smoke-doc")) === "hello2");

    // 统计（to_char 方言改写）
    const buckets = await db.all<{ sender: string; bucket: string; c: number }>(
      `SELECT sender, to_char(to_timestamp(ts / 1000.0) AT TIME ZONE 'UTC' + interval '8 hours', 'YYYY-MM-DD') AS bucket, COUNT(*) AS c
       FROM messages WHERE channel = 'couple' AND kind = 'user' AND sender != 'ai' AND ts >= ?
       GROUP BY sender, bucket ORDER BY bucket DESC LIMIT 5`,
      [Date.now() - 30 * 24 * 3600 * 1000],
    );
    assertOk(`统计聚合 → ${buckets.length} 桶，COUNT 是 number`, buckets.length > 0 && typeof buckets[0].c === "number");

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
