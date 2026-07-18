import { nanoid } from "nanoid";
import { all, get, run, transaction, type MessageRow, type ReadReceiptRow, type UploadRow } from "../db";
import type { SendMessagePayload } from "../contracts/realtime";
import type { AuthUser, ClientChannel, ClientMessage, ClientMessageAttachment, MessageKind, MessageType, StoredChannel } from "../types";
import { toClientChannel } from "../types";
import { domainEvents } from "../events/domainEvents";
import { errorCodes } from "../errors/errorCodes";
import { redactTraceForMessage } from "../ai/debug/trace";
import { conversationIdentity, conversationIdentityIn } from "../auth/identity";
import { appendSyncEvent } from "../sync/events";
import { enqueueTranscriptForMessage } from "../transcription/service";
import { refreshSignedMediaUrl } from "../upload/mediaAccess";
import { removeUploadArtifacts } from "../upload/thumbnail";

export type SendMessageInput = SendMessagePayload;
export interface FetchMessagesInput {
  channel: ClientChannel;
  since?: number;
  after?: number;
  before?: number;
  around?: number;
  /** 与 before 组成 (ts,id) 游标；缺省时仅 ts（兼容旧客户端）。 */
  beforeId?: string;
  afterId?: string;
  sinceId?: string;
  limit?: number;
}

function safeJson(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  return JSON.stringify(value);
}

function readJson(value: string | null): unknown {
  if (!value) return undefined;
  try {
    return JSON.parse(value);
  } catch {
    return undefined;
  }
}

function mapAttachments(value: unknown): ClientMessageAttachment[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.map((item) => {
    const attachment = item as ClientMessageAttachment;
    return {
      ...attachment,
      url: refreshSignedMediaUrl(attachment.url) ?? attachment.url,
    };
  });
}

function mapMessage(row: MessageRow, clientChannel?: ClientChannel): ClientMessage {
  const reply = readJson(row.reply_json);
  const replyObject = typeof reply === "object" && reply !== null ? (reply as Record<string, unknown>) : undefined;
  return {
    id: row.id,
    sender: row.sender,
    senderName: row.sender_name,
    kind: row.kind as MessageKind,
    type: row.type as MessageType,
    text: row.text,
    url: refreshSignedMediaUrl(row.url) ?? row.url ?? undefined,
    replyTo: typeof replyObject?.id === "string" ? replyObject.id : undefined,
    replyPreview: typeof replyObject?.preview === "string" ? replyObject.preview : undefined,
    meta: readJson(row.meta_json),
    attachments: mapAttachments(readJson(row.attachments_json)),
    recalledText: row.recalled_text ?? undefined,
    channel: clientChannel ?? toClientChannel(row.channel as StoredChannel),
    ts: row.ts,
    clientId: row.client_id ?? undefined,
    transcript: row.transcript_status ? {
      status: row.transcript_status as NonNullable<ClientMessage["transcript"]>["status"],
      text: row.transcript_text ?? "",
      rawText: row.transcript_raw_text ?? undefined,
      corrected: row.transcript_corrected ?? false,
      language: row.transcript_language ?? undefined,
      version: row.transcript_version ?? 0,
    } : undefined,
  };
}

/** 复合游标：有 id 时用 (ts,id)；仅有 ts 时退回旧语义。 */
function beforeClause(alias: string, ts: number, id?: string): { sql: string; params: Array<string | number> } {
  if (id) {
    return {
      sql: `(${alias}.ts < ? OR (${alias}.ts = ? AND ${alias}.id < ?))`,
      params: [ts, ts, id],
    };
  }
  return { sql: `${alias}.ts < ?`, params: [ts] };
}

function afterClause(alias: string, ts: number, id?: string, inclusive = false): { sql: string; params: Array<string | number> } {
  if (id) {
    if (inclusive) {
      return {
        sql: `(${alias}.ts > ? OR (${alias}.ts = ? AND ${alias}.id >= ?))`,
        params: [ts, ts, id],
      };
    }
    return {
      sql: `(${alias}.ts > ? OR (${alias}.ts = ? AND ${alias}.id > ?))`,
      params: [ts, ts, id],
    };
  }
  if (inclusive) return { sql: `${alias}.ts >= ?`, params: [ts] };
  return { sql: `${alias}.ts > ?`, params: [ts] };
}

const messageProjection = `message.*,
  transcript.status AS transcript_status,
  COALESCE(transcript.corrected_text, transcript.text) AS transcript_text,
  CASE WHEN transcript.corrected_text IS NULL THEN NULL ELSE transcript.text END AS transcript_raw_text,
  (transcript.corrected_text IS NOT NULL) AS transcript_corrected,
  transcript.language AS transcript_language,
  transcript.version AS transcript_version`;

function normalizedReply(input: SendMessageInput): unknown {
  if (!input.replyTo) return undefined;
  return {
    id: input.replyTo,
    preview: input.replyPreview ?? "",
  };
}

export async function createMessage(user: AuthUser, input: SendMessageInput): Promise<ClientMessage> {
  return transaction(async (db) => {
    const identity = await conversationIdentityIn(db, user, input.channel);
    if (!identity) throw new Error(errorCodes.unauthorized);
    const storedChannel = identity.storedChannel;
    const ts = Date.now();

    const loadByClientId = async () => {
      if (!input.clientId) return undefined;
      return user.deviceId
        ? await db.get<MessageRow>(
          `SELECT ${messageProjection} FROM messages message
           LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
           WHERE message.conversation_id = ? AND message.sender_account_id = ?
           AND message.origin_device_id = ? AND message.client_id = ?`,
          [identity.conversationId, identity.accountId, user.deviceId, input.clientId],
        )
        : await db.get<MessageRow>(`SELECT ${messageProjection} FROM messages message
            LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
            WHERE message.sender = ? AND message.client_id = ?`, [
            user.username,
            input.clientId,
          ]);
    };

    // clientId 是客户端离线队列的幂等键：重试必须返回原消息，不能重复写入。
    const existingByClientId = await loadByClientId();
    if (existingByClientId) return mapMessage(existingByClientId, input.channel);

    const requiresUpload = ["image", "video", "voice", "file"].includes(input.type) && !input.attachments?.length;
    let attachmentURL: string | null = input.url ?? null;
    let upload: UploadRow | undefined;
    const attachmentUploads: Array<{ upload: UploadRow; attachment: NonNullable<SendMessageInput["attachments"]>[number] }> = [];
    if (requiresUpload) {
      upload = await db.get<UploadRow>(
        "SELECT * FROM uploads WHERE id = ? AND owner = ? FOR UPDATE",
        [input.uploadId, user.username],
      );
      if (!upload) throw new Error("upload_not_found");
      if (upload.message_id) throw new Error("upload_already_attached");
      if (input.url && input.url !== upload.url) throw new Error("upload_url_mismatch");
      attachmentURL = upload.url;
    }
    if (input.attachments?.length) {
      for (const attachment of input.attachments) {
        const selected = await db.get<UploadRow>(
          "SELECT * FROM uploads WHERE id = ? AND owner = ? FOR UPDATE",
          [attachment.uploadId, user.username],
        );
        if (!selected) throw new Error("upload_not_found");
        if (selected.message_id) throw new Error("upload_already_attached");
        if (attachment.role === "photo" && !selected.mime_type.startsWith("image/")) {
          throw new Error("attachment_photo_type_mismatch");
        }
        if (attachment.role === "pairedVideo" && !selected.mime_type.startsWith("video/")) {
          throw new Error("attachment_video_type_mismatch");
        }
        attachmentUploads.push({ upload: selected, attachment });
      }
      const firstPhoto = attachmentUploads
        .filter((item) => item.attachment.role === "photo")
        .sort((a, b) => a.attachment.order - b.attachment.order)[0];
      attachmentURL = firstPhoto?.upload.url ?? null;
    }

    const clientAttachments: ClientMessageAttachment[] | undefined = attachmentUploads.length
      ? attachmentUploads
        .map(({ upload: selected, attachment }) => ({
          id: selected.id,
          assetId: attachment.assetId,
          role: attachment.role,
          order: attachment.order,
          url: selected.url,
          mimeType: selected.mime_type,
          size: selected.size,
        }))
        .sort((a, b) => a.order - b.order || a.role.localeCompare(b.role))
      : undefined;

    const row: MessageRow = {
      id: `msg_${nanoid(16)}`,
      channel: storedChannel,
      sender: user.username,
      sender_name: user.name,
      kind: "user",
      type: input.type,
      text: input.text ?? "",
      url: attachmentURL,
      reply_json: safeJson(normalizedReply(input)),
      meta_json: safeJson(input.meta),
      attachments_json: safeJson(clientAttachments),
      recalled_text: null,
      ts,
      client_id: input.clientId ?? null,
      conversation_id: identity.conversationId,
      sender_account_id: identity.accountId,
      origin_device_id: user.deviceId ?? null,
      server_seq: null,
    };

    try {
      await db.run(
        `INSERT INTO messages
          (id, channel, sender, sender_name, kind, type, text, url, reply_json, meta_json,
           attachments_json, ts, client_id, conversation_id, sender_account_id, origin_device_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          row.id,
          row.channel,
          row.sender,
          row.sender_name,
          row.kind,
          row.type,
          row.text,
          row.url,
          row.reply_json,
          row.meta_json,
          row.attachments_json,
          row.ts,
          row.client_id,
          row.conversation_id,
          row.sender_account_id,
          row.origin_device_id,
        ],
      );
    } catch (error) {
      // 并发重试可能撞唯一索引：回查原消息而不是 500。
      const code = (error as { code?: string })?.code;
      if (input.clientId && (code === "23505" || String(error).includes("unique"))) {
        const raced = await loadByClientId();
        if (raced) return mapMessage(raced, input.channel);
      }
      throw error;
    }

    if (upload) {
      const bound = await db.run(
        "UPDATE uploads SET message_id = ?, purpose = 'message' WHERE id = ? AND owner = ? AND message_id IS NULL",
        [row.id, upload.id, user.username],
      );
      if (bound !== 1) throw new Error("upload_already_attached");
    }
    for (const { upload: selected, attachment } of attachmentUploads) {
      const bound = await db.run(
        "UPDATE uploads SET message_id = ?, purpose = 'message' WHERE id = ? AND owner = ? AND message_id IS NULL",
        [row.id, selected.id, user.username],
      );
      if (bound !== 1) throw new Error("upload_already_attached");
      await db.run(
        `INSERT INTO message_attachments (id, message_id, upload_id, asset_id, role, sort_order)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [`att_${nanoid(16)}`, row.id, selected.id, attachment.assetId, attachment.role, attachment.order],
      );
    }
    if (input.type === "voice") {
      row.transcript_status = await enqueueTranscriptForMessage(db, identity, row.id, ts);
      row.transcript_text = "";
      row.transcript_corrected = false;
      row.transcript_version = 0;
    }
    return mapMessage(row, input.channel);
  });
}

export async function createAiMessage(
  channel: StoredChannel,
  text: string,
  meta?: unknown,
  user?: AuthUser,
): Promise<ClientMessage> {
  const clientChannel: ClientChannel = channel.startsWith("ai:") ? "ai" : "couple";
  const identity = user ? await conversationIdentity(user, clientChannel) : null;
  const conversation = identity
    ? { id: identity.conversationId }
    : channel === "couple"
    ? await get<{ id: string }>(
        "SELECT id FROM conversations WHERE kind = 'couple' AND couple_id = 'cpl_legacy_xusi' AND archived_at IS NULL",
      )
    : await get<{ id: string }>(
        `SELECT conversation.id FROM conversations conversation
         JOIN accounts account ON account.id = conversation.owner_account_id
         WHERE conversation.kind = 'ai' AND account.username = ? AND conversation.archived_at IS NULL`,
        [channel.slice("ai:".length)],
      );
  if (!conversation) throw new Error(errorCodes.unauthorized);
  const metaJson = meta !== undefined && meta !== null ? JSON.stringify(meta) : null;
  const row: MessageRow = {
    id: `ai_${nanoid(16)}`,
    channel,
    sender: "ai",
    sender_name: "大橘",
    kind: "user",
    type: "text",
    text,
    url: null,
    reply_json: null,
    meta_json: metaJson,
    attachments_json: null,
    recalled_text: null,
    ts: Date.now(),
    client_id: null,
    conversation_id: conversation?.id ?? null,
    sender_account_id: null,
    origin_device_id: null,
    server_seq: null,
  };

  await run(
    `INSERT INTO messages
      (id, channel, sender, sender_name, kind, type, text, url, reply_json, meta_json,
       attachments_json, ts, client_id, conversation_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      row.id,
      row.channel,
      row.sender,
      row.sender_name,
      row.kind,
      row.type,
      row.text,
      row.url,
      row.reply_json,
      row.meta_json,
      row.attachments_json,
      row.ts,
      row.client_id,
      row.conversation_id,
    ],
  );

  return mapMessage(row, clientChannel);
}

export async function fetchMessages(user: AuthUser, input: FetchMessagesInput) {
  const identity = await conversationIdentity(user, input.channel);
  if (!identity) return [];
  const conversationId = identity.conversationId;
  const limit = Math.min(Math.max(input.limit ?? 80, 1), 300);
  const projection = `SELECT ${messageProjection} FROM messages message
     LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id`;

  if (input.after !== undefined && input.before !== undefined) {
    const after = afterClause("message", input.after, input.afterId, true);
    const before = beforeClause("message", input.before, input.beforeId);
    const rows = await all<MessageRow>(
      `${projection}
       WHERE message.conversation_id = ? AND ${after.sql} AND ${before.sql}
       ORDER BY message.ts ASC, message.id ASC LIMIT ?`,
      [conversationId, ...after.params, ...before.params, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.before !== undefined) {
    const before = beforeClause("message", input.before, input.beforeId);
    const rows = await all<MessageRow>(
      `${projection}
       WHERE message.conversation_id = ? AND ${before.sql}
       ORDER BY message.ts DESC, message.id DESC LIMIT ?`,
      [conversationId, ...before.params, limit],
    );
    return rows.reverse().map((row) => mapMessage(row, input.channel));
  }

  if (input.since !== undefined) {
    const since = afterClause("message", input.since, input.sinceId, false);
    const rows = await all<MessageRow>(
      `${projection}
       WHERE message.conversation_id = ? AND ${since.sql}
       ORDER BY message.ts ASC, message.id ASC LIMIT ?`,
      [conversationId, ...since.params, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.after !== undefined) {
    const after = afterClause("message", input.after, input.afterId, true);
    const rows = await all<MessageRow>(
      `${projection}
       WHERE message.conversation_id = ? AND ${after.sql}
       ORDER BY message.ts ASC, message.id ASC LIMIT ?`,
      [conversationId, ...after.params, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.around) {
    const half = Math.max(Math.floor(limit / 2), 1);
    const before = beforeClause("message", input.around, undefined);
    const after = afterClause("message", input.around, undefined, false);
    const older = await all<MessageRow>(
      `${projection}
       WHERE message.conversation_id = ? AND ${before.sql}
       ORDER BY message.ts DESC, message.id DESC LIMIT ?`,
      [conversationId, ...before.params, half],
    );
    // around 锚点毫秒内的消息也纳入（含同 ts 全 id 段），减少漏行。
    const aroundEqual = await all<MessageRow>(
      `${projection}
       WHERE message.conversation_id = ? AND message.ts = ?
       ORDER BY message.ts ASC, message.id ASC LIMIT ?`,
      [conversationId, input.around, limit],
    );
    const newer = await all<MessageRow>(
      `${projection}
       WHERE message.conversation_id = ? AND ${after.sql}
       ORDER BY message.ts ASC, message.id ASC LIMIT ?`,
      [conversationId, ...after.params, half],
    );
    const merged = new Map<string, MessageRow>();
    for (const row of [...older.reverse(), ...aroundEqual, ...newer]) merged.set(row.id, row);
    return [...merged.values()]
      .sort((a, b) => a.ts - b.ts || a.id.localeCompare(b.id))
      .slice(0, limit)
      .map((row) => mapMessage(row, input.channel));
  }

  const rows = await all<MessageRow>(
    `${projection}
     WHERE message.conversation_id = ? ORDER BY message.ts DESC, message.id DESC LIMIT ?`,
    [conversationId, limit],
  );
  return rows.reverse().map((row) => mapMessage(row, input.channel));
}

export async function countMessages(user: AuthUser, channel: ClientChannel) {
  const identity = await conversationIdentity(user, channel);
  if (!identity) return 0;
  const row = await get<{ count: number | string }>(
    "SELECT COUNT(*) AS count FROM messages WHERE conversation_id = ?",
    [identity.conversationId],
  );
  return Number(row?.count ?? 0);
}

export async function fetchMessageById(user: AuthUser, channel: ClientChannel, id: string) {
  const identity = await conversationIdentity(user, channel);
  if (!identity) return null;
  const row = await get<MessageRow>(
    `SELECT ${messageProjection} FROM messages message
     LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
     WHERE message.conversation_id = ? AND message.id = ?
     LIMIT 1`,
    [identity.conversationId, id],
  );
  return row ? mapMessage(row, channel) : null;
}

export interface MessageSearchCursor {
  ts: number;
  id: string;
}

export interface MessageSearchPage {
  list: ClientMessage[];
  hasMore: boolean;
  nextCursor: MessageSearchCursor | null;
}

export async function searchMessages(
  user: AuthUser,
  channel: ClientChannel,
  query: string,
  limit = 50,
  cursor?: MessageSearchCursor,
): Promise<MessageSearchPage> {
  const identity = await conversationIdentity(user, channel);
  if (!identity) return { list: [], hasMore: false, nextCursor: null };
  const pageSize = Math.min(Math.max(limit, 1), 100);
  const cursorClause = cursor
    ? "AND (message.ts < ? OR (message.ts = ? AND message.id < ?))"
    : "";
  const params: unknown[] = [identity.conversationId, `%${query}%`, `%${query}%`];
  if (cursor) params.push(cursor.ts, cursor.ts, cursor.id);
  params.push(pageSize + 1);
  const rows = await all<MessageRow>(
    `SELECT ${messageProjection} FROM messages message
     LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
     WHERE message.conversation_id = ?
       AND (message.text ILIKE ? OR COALESCE(transcript.corrected_text, transcript.text, '') ILIKE ?)
       ${cursorClause}
     ORDER BY message.ts DESC, message.id DESC LIMIT ?`,
    params,
  );
  const hasMore = rows.length > pageSize;
  const pageRows = rows.slice(0, pageSize);
  const last = pageRows.at(-1);
  return {
    list: pageRows.map((row) => mapMessage(row, channel)),
    hasMore,
    nextCursor: hasMore && last ? { ts: last.ts, id: last.id } : null,
  };
}

export async function recallMessage(user: AuthUser, id: string) {
  const recallRequestedAt = Date.now();
  const result = await transaction(async (db) => {
    const identity = await conversationIdentityIn(db, user, "couple")
      ?? await conversationIdentityIn(db, user, "ai");
    if (!identity) return null;
    const existing = await db.get<MessageRow>(
      `SELECT message.* FROM messages message
       LEFT JOIN conversations conversation ON conversation.id = message.conversation_id
       WHERE message.id = ? AND message.sender = ?
         AND (message.conversation_id IS NULL
           OR conversation.owner_account_id = ? OR conversation.couple_id = ?)
       FOR UPDATE OF message`,
      [id, user.username, identity.accountId, identity.coupleId ?? ""],
    );
    if (!existing) return null;
    if (existing.kind !== "user" || recallRequestedAt - existing.ts > 120_000 || existing.ts > recallRequestedAt + 5_000) {
      throw new Error(errorCodes.recallWindowExpired);
    }

    const uploads = await db.all<UploadRow>(
      "SELECT * FROM uploads WHERE message_id = ? OR (url = ? AND purpose = 'message') FOR UPDATE",
      [id, existing.url ?? ""],
    );
    // 只清本会话内引用，避免全表 FOR UPDATE。
    const replies = existing.conversation_id
      ? await db.all<{ id: string; reply_json: string }>(
        `SELECT id, reply_json FROM messages
          WHERE conversation_id = ? AND reply_json IS NOT NULL FOR UPDATE`,
        [existing.conversation_id],
      )
      : await db.all<{ id: string; reply_json: string }>(
        `SELECT id, reply_json FROM messages
          WHERE channel = ? AND reply_json IS NOT NULL FOR UPDATE`,
        [existing.channel],
      );
    for (const reply of replies) {
      try {
        const value = JSON.parse(reply.reply_json) as { id?: unknown };
        if (value.id === id) await db.run("UPDATE messages SET reply_json = NULL WHERE id = ?", [reply.id]);
      } catch {
        // 历史第三方客户端可能留下非法 JSON；撤回不能因此失败。
      }
    }
    await db.run(
      `DELETE FROM ai_memory_import_candidates candidate
       WHERE EXISTS (
         SELECT 1 FROM ai_memory_import_evidence evidence
          WHERE evidence.candidate_id = candidate.id AND evidence.message_id = ?
       )`,
      [id],
    );
    await db.run("DELETE FROM messages WHERE id = ?", [id]);
    for (const uploadItem of uploads) {
      await db.run(
        `INSERT INTO file_cleanup_queue (id, path, reason, created_at)
         VALUES (?, ?, 'message_recalled', ?) ON CONFLICT(id) DO NOTHING`,
        [`cleanup_${uploadItem.id}`, uploadItem.path, recallRequestedAt],
      );
      await db.run("DELETE FROM uploads WHERE id = ?", [uploadItem.id]);
    }
    await db.run("DELETE FROM ai_runtime_state WHERE key = ?", [`context:${existing.channel}`]);
    await db.run("DELETE FROM ai_runtime_state WHERE key = ?", [`context:v2:${existing.channel}`]);
    // 旧 legacy AI 表仅按 channel 清理 episodes；不再全局清空 ai_facts/ai_docs。
    await db.run("DELETE FROM ai_episodes WHERE channel = ?", [existing.channel]);

    const conversation = existing.conversation_id
      ? await db.get<{ id: string; couple_id: string | null; owner_account_id: string | null }>(
          "SELECT id, couple_id, owner_account_id FROM conversations WHERE id = ?",
          [existing.conversation_id],
        )
      : undefined;
    let notice: ClientMessage | undefined;
    if (conversation && existing.conversation_id) {
      const noticeRow: MessageRow = {
        id: `msg_${nanoid(16)}`,
        channel: existing.channel,
        sender: user.username,
        sender_name: user.name,
        kind: "system",
        type: "text",
        text: `${user.name}撤回了一条消息`,
        url: null,
        reply_json: null,
        meta_json: safeJson({
          recallNotice: { messageId: id, by: user.username, byName: user.name },
        }),
        attachments_json: null,
        recalled_text: null,
        ts: recallRequestedAt,
        client_id: null,
        conversation_id: existing.conversation_id,
        sender_account_id: identity.accountId,
        origin_device_id: user.deviceId ?? null,
        server_seq: null,
      };
      await db.run(
        `INSERT INTO messages
         (id, channel, sender, sender_name, kind, type, text, url, reply_json, meta_json,
          attachments_json, ts, client_id, conversation_id, sender_account_id, origin_device_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [noticeRow.id, noticeRow.channel, noticeRow.sender, noticeRow.sender_name,
          noticeRow.kind, noticeRow.type, noticeRow.text, noticeRow.url, noticeRow.reply_json,
          noticeRow.meta_json, noticeRow.attachments_json, noticeRow.ts, noticeRow.client_id,
          noticeRow.conversation_id, noticeRow.sender_account_id, noticeRow.origin_device_id],
      );
      notice = mapMessage(noticeRow, toClientChannel(existing.channel as StoredChannel));
    }
    const syncCursor = conversation ? await appendSyncEvent(db, {
      coupleId: conversation.couple_id,
      accountId: conversation.owner_account_id,
      entityType: "message",
      entityId: id,
      operation: "delete",
      payload: { id, channel: toClientChannel(existing.channel as StoredChannel) },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: recallRequestedAt,
    }) : null;

    return {
      recalled: {
        id,
        channel: toClientChannel(existing.channel as StoredChannel),
        by: user.username,
        byName: user.name,
        deleted: true,
        notice,
        syncCursor: syncCursor ?? undefined,
      },
      uploadCleanup: uploads.map((item) => ({ id: `cleanup_${item.id}`, path: item.path })),
    };
  });
  if (!result) return null;
  // 数据库事务已完成后，客户端就可以立即移除消息。事件发布、追踪脱敏和
  // 磁盘回收都不是撤回确认的前置条件，放到后台避免长按撤回后继续等 I/O。
  void (async () => {
    try { await domainEvents.publish("message.recalled", { messageId: id }); } catch (error) {
      console.warn(`[recall] domain event failed id=${id}: ${error instanceof Error ? error.message : String(error)}`);
    }
    try { await redactTraceForMessage(id); } catch (error) {
      console.warn(`[recall] trace redaction failed id=${id}: ${error instanceof Error ? error.message : String(error)}`);
    }
    for (const item of result.uploadCleanup) {
      try {
        await removeUploadArtifacts(item.path);
        await run(
          `UPDATE file_cleanup_queue SET completed_at = ?, attempt_count = attempt_count + 1,
           last_error = NULL WHERE id = ? AND completed_at IS NULL`,
          [Date.now(), item.id],
        );
      } catch (error) {
        console.warn(`[upload] 撤回消息后删除文件失败 id=${id}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  })();
  return result.recalled;
}

export async function upsertReadReceipt(user: AuthUser, channel: ClientChannel, ts: number) {
  const identity = await conversationIdentity(user, channel);
  if (!identity) return 0;
  const now = Date.now();
  const latest = await get<{ ts: number | null }>(
    "SELECT MAX(ts) AS ts FROM messages WHERE conversation_id = ?",
    [identity.conversationId],
  );
  const boundedTs = Math.min(Math.round(ts), now, latest?.ts ?? 0);
  if (boundedTs <= 0) {
    const existing = await get<ReadReceiptRow>(
      "SELECT * FROM read_receipts WHERE channel = ? AND username = ?",
      [identity.storedChannel, user.username],
    );
    return existing?.ts ?? 0;
  }
  return transaction(async (db) => {
    await db.run(
      `INSERT INTO read_receipts (channel, username, ts, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(channel, username) DO UPDATE
         SET ts = GREATEST(read_receipts.ts, excluded.ts), updated_at = excluded.updated_at`,
      [identity.storedChannel, user.username, boundedTs, now],
    );
    const visible = await db.get<{ id: string; server_seq: number }>(
      `SELECT id, server_seq FROM messages
       WHERE conversation_id = ? AND ts <= ?
       ORDER BY server_seq DESC LIMIT 1`,
      [identity.conversationId, boundedTs],
    );
    if (visible) {
      await db.run(
        `INSERT INTO conversation_reads
         (conversation_id, account_id, last_read_message_id, last_read_server_seq,
          updated_by_device_id, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(conversation_id, account_id) DO UPDATE SET
           last_read_message_id = CASE
             WHEN excluded.last_read_server_seq > conversation_reads.last_read_server_seq
             THEN excluded.last_read_message_id ELSE conversation_reads.last_read_message_id END,
           last_read_server_seq = GREATEST(
             conversation_reads.last_read_server_seq, excluded.last_read_server_seq),
           updated_by_device_id = CASE
             WHEN excluded.last_read_server_seq > conversation_reads.last_read_server_seq
             THEN excluded.updated_by_device_id ELSE conversation_reads.updated_by_device_id END,
           updated_at = excluded.updated_at`,
        [identity.conversationId, identity.accountId, visible.id, visible.server_seq,
          user.deviceId ?? null, now],
      );
    }
    const receipt = await db.get<ReadReceiptRow>(
      "SELECT * FROM read_receipts WHERE channel = ? AND username = ?",
      [identity.storedChannel, user.username],
    );
    return receipt?.ts ?? boundedTs;
  });
}

export async function getReadReceipts(user: AuthUser, channel: ClientChannel) {
  const identity = await conversationIdentity(user, channel);
  if (!identity) return {};
  const rows = await all<{ username: string; ts: number }>(
    `SELECT account.username, COALESCE(message.ts, 0) AS ts
       FROM conversation_reads receipt
       JOIN accounts account ON account.id = receipt.account_id
       LEFT JOIN messages message ON message.id = receipt.last_read_message_id
      WHERE receipt.conversation_id = ?`,
    [identity.conversationId],
  );
  return Object.fromEntries(rows.map((row) => [row.username, row.ts]));
}
