import { nanoid } from "nanoid";
import { all, get, run, type MessageRow, type ReadReceiptRow } from "../db";
import type { AuthUser, ClientChannel, ClientMessage, MessageKind, MessageType, StoredChannel } from "../types";
import { toClientChannel, toStoredChannel } from "../types";

export interface SendMessageInput {
  channel: ClientChannel;
  type: MessageType;
  text?: string;
  url?: string;
  replyTo?: string;
  replyPreview?: string;
  reply?: unknown;
  meta?: unknown;
  clientId?: string;
}

export interface FetchMessagesInput {
  channel: ClientChannel;
  since?: number;
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
  const storedChannel = toStoredChannel(input.channel, user.username);
  const ts = Date.now();

  if (input.clientId) {
    const existing = get<MessageRow>("SELECT * FROM messages WHERE sender = ? AND client_id = ?", [
      user.username,
      input.clientId,
    ]);
    if (existing) return mapMessage(existing, input.channel);
  }

  const row: MessageRow = {
    id: `msg_${nanoid(16)}`,
    channel: storedChannel,
    sender: user.username,
    sender_name: user.name,
    kind: "user",
    type: input.type,
    text: input.text ?? "",
    url: input.url ?? null,
    reply_json: safeJson(normalizedReply(input)),
    meta_json: safeJson(input.meta),
    ts,
    client_id: input.clientId ?? null,
  };

  run(
    `INSERT INTO messages
      (id, channel, sender, sender_name, kind, type, text, url, reply_json, meta_json, ts, client_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
      row.ts,
      row.client_id,
    ],
  );
  return mapMessage(row, input.channel);
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
    ts: Date.now(),
    client_id: null,
  };
  run(
    `INSERT INTO messages
      (id, channel, sender, sender_name, kind, type, text, url, reply_json, meta_json, ts, client_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
      row.ts,
      row.client_id,
    ],
  );
  return mapMessage(row);
}

export async function createAiMessage(channel: StoredChannel, text: string): Promise<ClientMessage> {
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
    meta_json: null,
    ts: Date.now(),
    client_id: null,
  };

  run(
    `INSERT INTO messages
      (id, channel, sender, sender_name, kind, type, text, url, reply_json, meta_json, ts, client_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
      row.ts,
      row.client_id,
    ],
  );

  return mapMessage(row);
}

export async function fetchMessages(user: AuthUser, input: FetchMessagesInput) {
  const storedChannel = toStoredChannel(input.channel, user.username);
  const limit = Math.min(Math.max(input.limit ?? 80, 1), 300);

  if (input.before) {
    const rows = all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts < ? ORDER BY ts DESC LIMIT ?",
      [storedChannel, input.before, limit],
    );
    return rows.reverse().map((row) => mapMessage(row, input.channel));
  }

  if (input.since) {
    const rows = all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts > ? ORDER BY ts ASC LIMIT ?",
      [storedChannel, input.since, limit],
    );
    return rows.map((row) => mapMessage(row, input.channel));
  }

  if (input.around) {
    const half = Math.max(Math.floor(limit / 2), 1);
    const before = all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts < ? ORDER BY ts DESC LIMIT ?",
      [storedChannel, input.around, half],
    );
    const after = all<MessageRow>(
      "SELECT * FROM messages WHERE channel = ? AND ts > ? ORDER BY ts ASC LIMIT ?",
      [storedChannel, input.around, half],
    );
    return [...before.reverse(), ...after].map((row) => mapMessage(row, input.channel));
  }

  const rows = all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? ORDER BY ts DESC LIMIT ?",
    [storedChannel, limit],
  );
  return rows.reverse().map((row) => mapMessage(row, input.channel));
}

export async function searchMessages(user: AuthUser, channel: ClientChannel, query: string, limit = 50) {
  const storedChannel = toStoredChannel(channel, user.username);
  const rows = all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? AND text LIKE ? ORDER BY ts DESC LIMIT ?",
    [storedChannel, `%${query}%`, Math.min(limit, 100)],
  );
  return rows.map((row) => mapMessage(row, channel));
}

export async function recallMessage(user: AuthUser, id: string) {
  const existing = get<MessageRow>("SELECT * FROM messages WHERE id = ? AND sender = ?", [id, user.username]);
  if (!existing) return null;

  const text = "你撤回了一条消息";
  run(
    `UPDATE messages
     SET kind = 'system', type = 'text', text = ?, url = NULL, reply_json = NULL, meta_json = NULL
     WHERE id = ?`,
    [text, id],
  );

  return {
    id,
    channel: toClientChannel(existing.channel as StoredChannel),
    by: user.username,
    byName: user.name,
  };
}

export async function upsertReadReceipt(user: AuthUser, channel: ClientChannel, ts: number) {
  const storedChannel = toStoredChannel(channel, user.username);
  const now = Date.now();
  run(
    `INSERT INTO read_receipts (channel, username, ts, updated_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(channel, username) DO UPDATE SET ts = excluded.ts, updated_at = excluded.updated_at`,
    [storedChannel, user.username, ts, now],
  );
}

export async function getReadReceipts(user: AuthUser, channel: ClientChannel) {
  const storedChannel = toStoredChannel(channel, user.username);
  const rows = all<ReadReceiptRow>("SELECT * FROM read_receipts WHERE channel = ?", [storedChannel]);
  return Object.fromEntries(rows.map((row) => [row.username, row.ts]));
}
