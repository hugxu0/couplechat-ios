import fs from "node:fs/promises";
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

export type SendMessageInput = SendMessagePayload;
export interface FetchMessagesInput {
  channel: ClientChannel;
  since?: number;
  after?: number;
  before?: number;
  around?: number;
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
    url: row.url ?? undefined,
    replyTo: typeof replyObject?.id === "string" ? replyObject.id : undefined,
    replyPreview: typeof replyObject?.preview === "string" ? replyObject.preview : undefined,
    reply,
    meta: readJson(row.meta_json),
    attachments: (readJson(row.attachments_json) as ClientMessageAttachment[] | undefined) ?? undefined,
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

const messageProjection = `message.*,
  transcript.status AS transcript_status,
  COALESCE(transcript.corrected_text, transcript.text) AS transcript_text,
  CASE WHEN transcript.corrected_text IS NULL THEN NULL ELSE transcript.text END AS transcript_raw_text,
  (transcript.corrected_text IS NOT NULL) AS transcript_corrected,
  transcript.language AS transcript_language,
  transcript.version AS transcript_version`;

function normalizedReply(input: SendMessageInput): unknown {
  if (input.reply !== undefined) return input.reply;
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

    // clientId 是客户端离线队列的幂等键：重试必须返回原消息，不能重复写入。
    if (input.clientId) {
      const existing = user.deviceId
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
      if (existing) return mapMessage(existing, input.channel);
    }

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

  if (input.after !== undefined && input.before !== undefined) {
    const rows = await all<MessageRow>(
      `SELECT ${messageProjection} FROM messages message
       LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
       WHERE message.conversation_id = ? AND message.ts >= ? AND message.ts < ?
       ORDER BY message.ts ASC LIMIT ?`,
      [conversationId, input.after, input.before, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.before !== undefined) {
    const rows = await all<MessageRow>(
      `SELECT ${messageProjection} FROM messages message
       LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
       WHERE message.conversation_id = ? AND message.ts < ? ORDER BY message.ts DESC LIMIT ?`,
      [conversationId, input.before, limit],
    );
    return rows.reverse().map((row) => mapMessage(row, input.channel));
  }

  if (input.since !== undefined) {
    const rows = await all<MessageRow>(
      `SELECT ${messageProjection} FROM messages message
       LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
       WHERE message.conversation_id = ? AND message.ts > ? ORDER BY message.ts ASC LIMIT ?`,
      [conversationId, input.since, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.after !== undefined) {
    const rows = await all<MessageRow>(
      `SELECT ${messageProjection} FROM messages message
       LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
       WHERE message.conversation_id = ? AND message.ts >= ? ORDER BY message.ts ASC LIMIT ?`,
      [conversationId, input.after, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.around) {
    const half = Math.max(Math.floor(limit / 2), 1);
    const before = await all<MessageRow>(
      `SELECT ${messageProjection} FROM messages message
       LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
       WHERE message.conversation_id = ? AND message.ts < ? ORDER BY message.ts DESC LIMIT ?`,
      [conversationId, input.around, half],
    );
    const after = await all<MessageRow>(
      `SELECT ${messageProjection} FROM messages message
       LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
       WHERE message.conversation_id = ? AND message.ts > ? ORDER BY message.ts ASC LIMIT ?`,
      [conversationId, input.around, half],
    );
    return [...before.reverse(), ...after].map((row) => mapMessage(row, input.channel));
  }

  const rows = await all<MessageRow>(
    `SELECT ${messageProjection} FROM messages message
     LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
     WHERE message.conversation_id = ? ORDER BY message.ts DESC LIMIT ?`,
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

export async function searchMessages(user: AuthUser, channel: ClientChannel, query: string, limit = 50) {
  const identity = await conversationIdentity(user, channel);
  if (!identity) return [];
  const rows = await all<MessageRow>(
    `SELECT ${messageProjection} FROM messages message
     LEFT JOIN message_transcripts transcript ON transcript.message_id = message.id
     WHERE message.conversation_id = ?
       AND (message.text ILIKE ? OR COALESCE(transcript.corrected_text, transcript.text, '') ILIKE ?)
     ORDER BY message.ts DESC LIMIT ?`,
    [identity.conversationId, `%${query}%`, `%${query}%`, Math.min(limit, 100)],
  );
  return rows.map((row) => mapMessage(row, channel));
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
    const replies = await db.all<{ id: string; reply_json: string }>(
      "SELECT id, reply_json FROM messages WHERE reply_json IS NOT NULL FOR UPDATE",
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
    if (existing.channel === "couple") {
      await db.run("DELETE FROM ai_runtime_state WHERE key LIKE 'diary:%'");
    }
    // 旧三张 AI 表没有 evidence 外键，无法定向证明内容来源；它们已不再被 runtime
    // 使用，撤回时清空比继续保留可能含原文的历史派生更符合硬删除语义。
    await db.run("DELETE FROM ai_facts");
    await db.run("DELETE FROM ai_episodes WHERE channel = ?", [existing.channel]);
    await db.run("DELETE FROM ai_docs");

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
        await fs.rm(item.path, { force: true });
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
