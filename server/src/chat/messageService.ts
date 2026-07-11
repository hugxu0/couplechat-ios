import fs from "node:fs/promises";
import { nanoid } from "nanoid";
import { all, get, run, transaction, type MessageRow, type ReadReceiptRow, type UploadRow } from "../db";
import type { SendMessagePayload } from "../contracts/realtime";
import type { AuthUser, ClientChannel, ClientMessage, ClientMessageAttachment, MessageKind, MessageType, StoredChannel } from "../types";
import { toClientChannel, toStoredChannel } from "../types";
import { invalidateMemoriesForRecalledMessage } from "../ai/memory/store";

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
  };
}

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
    const storedChannel = toStoredChannel(input.channel, user.username);
    const ts = Date.now();

    // clientId 是客户端离线队列的幂等键：重试必须返回原消息，不能重复写入。
    if (input.clientId) {
      const existing = await db.get<MessageRow>("SELECT * FROM messages WHERE sender = ? AND client_id = ?", [
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
    };

    await db.run(
      `INSERT INTO messages
        (id, channel, sender, sender_name, kind, type, text, url, reply_json, meta_json, attachments_json, ts, client_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
    return mapMessage(row, input.channel);
  });
}

export async function createSystemMessage(channel: StoredChannel, text: string): Promise<ClientMessage> {
  const row: MessageRow = {
    id: `sys_${nanoid(16)}`,
    channel,
    sender: "system",
    sender_name: "系统",
    kind: "system",
    type: "text",
    text,
    url: null,
    reply_json: null,
    meta_json: null,
    attachments_json: null,
    recalled_text: null,
    ts: Date.now(),
    client_id: null,
  };
  await run(
    `INSERT INTO messages
      (id, channel, sender, sender_name, kind, type, text, url, reply_json, meta_json, attachments_json, ts, client_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
    ],
  );
  return mapMessage(row);
}

export async function createAiMessage(channel: StoredChannel, text: string, meta?: unknown): Promise<ClientMessage> {
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
  };

  await run(
    `INSERT INTO messages
      (id, channel, sender, sender_name, kind, type, text, url, reply_json, meta_json, attachments_json, ts, client_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
    ],
  );

  return mapMessage(row);
}

export async function fetchMessages(user: AuthUser, input: FetchMessagesInput) {
  const storedChannel = toStoredChannel(input.channel, user.username);
  const limit = Math.min(Math.max(input.limit ?? 80, 1), 300);

  if (input.after !== undefined && input.before !== undefined) {
    const rows = await all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts >= ? AND ts < ? ORDER BY ts ASC LIMIT ?",
      [storedChannel, input.after, input.before, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.before !== undefined) {
    const rows = await all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts < ? ORDER BY ts DESC LIMIT ?",
      [storedChannel, input.before, limit],
    );
    return rows.reverse().map((row) => mapMessage(row, input.channel));
  }

  if (input.since !== undefined) {
    const rows = await all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts > ? ORDER BY ts ASC LIMIT ?",
      [storedChannel, input.since, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.after !== undefined) {
    const rows = await all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts >= ? ORDER BY ts ASC LIMIT ?",
      [storedChannel, input.after, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.around) {
    const half = Math.max(Math.floor(limit / 2), 1);
    const before = await all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts < ? ORDER BY ts DESC LIMIT ?",
      [storedChannel, input.around, half],
    );
    const after = await all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts > ? ORDER BY ts ASC LIMIT ?",
      [storedChannel, input.around, half],
    );
    return [...before.reverse(), ...after].map((row) => mapMessage(row, input.channel));
  }

  const rows = await all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? ORDER BY ts DESC LIMIT ?",
    [storedChannel, limit],
  );
  return rows.reverse().map((row) => mapMessage(row, input.channel));
}

export async function countMessages(user: AuthUser, channel: ClientChannel) {
  const storedChannel = toStoredChannel(channel, user.username);
  const row = await get<{ count: number | string }>(
    "SELECT COUNT(*) AS count FROM messages WHERE channel = ?",
    [storedChannel],
  );
  return Number(row?.count ?? 0);
}

export async function searchMessages(user: AuthUser, channel: ClientChannel, query: string, limit = 50) {
  const storedChannel = toStoredChannel(channel, user.username);
  const rows = await all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? AND text LIKE ? ORDER BY ts DESC LIMIT ?",
    [storedChannel, `%${query}%`, Math.min(limit, 100)],
  );
  return rows.map((row) => mapMessage(row, channel));
}

export async function recallMessage(user: AuthUser, id: string) {
  const result = await transaction(async (db) => {
    const existing = await db.get<MessageRow>(
      "SELECT * FROM messages WHERE id = ? AND sender = ? FOR UPDATE",
      [id, user.username],
    );
    if (!existing) return null;

    const uploads = await db.all<UploadRow>(
      "SELECT * FROM uploads WHERE message_id = ? OR (url = ? AND purpose = 'message') FOR UPDATE",
      [id, existing.url ?? ""],
    );
    await db.run(
      `UPDATE messages
       SET kind = 'system', type = 'text', text = ?, recalled_text = ?, url = NULL,
           reply_json = NULL, meta_json = NULL, attachments_json = NULL
       WHERE id = ?`,
      ["你撤回了一条消息", existing.type === "text" ? existing.text : null, id],
    );
    await db.run("DELETE FROM message_attachments WHERE message_id = ?", [id]);
    for (const uploadItem of uploads) {
      await db.run("DELETE FROM uploads WHERE id = ?", [uploadItem.id]);
    }

    return {
      recalled: {
        id,
        channel: toClientChannel(existing.channel as StoredChannel),
        by: user.username,
        byName: user.name,
        recalledText: existing.type === "text" ? existing.text : undefined,
      },
      uploadPaths: uploads.map((item) => item.path),
    };
  });
  if (!result) return null;
  await invalidateMemoriesForRecalledMessage(id).catch((error) => {
    console.warn(`[memory] 撤回证据传播失败 id=${id}: ${error instanceof Error ? error.message : String(error)}`);
  });
  for (const uploadPath of result.uploadPaths) {
    await fs.rm(uploadPath, { force: true }).catch((error) => {
      console.warn(`[upload] 撤回消息后删除文件失败 id=${id}: ${error instanceof Error ? error.message : String(error)}`);
    });
  }
  return result.recalled;
}

export async function upsertReadReceipt(user: AuthUser, channel: ClientChannel, ts: number) {
  const storedChannel = toStoredChannel(channel, user.username);
  const now = Date.now();
  await run(
    `INSERT INTO read_receipts (channel, username, ts, updated_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(channel, username) DO UPDATE SET ts = excluded.ts, updated_at = excluded.updated_at`,
    [storedChannel, user.username, ts, now],
  );
}

export async function getReadReceipts(user: AuthUser, channel: ClientChannel) {
  const storedChannel = toStoredChannel(channel, user.username);
  const rows = await all<ReadReceiptRow>("SELECT * FROM read_receipts WHERE channel = ?", [storedChannel]);
  return Object.fromEntries(rows.map((row) => [row.username, row.ts]));
}
