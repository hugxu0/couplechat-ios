// 读取聊天记录并压缩为适合模型输入的单行文本。

import { all, type MessageRow } from "../../db";
import type { ClientMessageAttachment } from "../../types";
import { beijingClock } from "../time";
import { CONTEXT } from "../settings";

export interface LogMessage {
  id: string;
  sender: string;
  senderName: string;
  kind: string;
  type: string;
  text: string;
  url: string | null;
  attachments: ClientMessageAttachment[];
  ts: number;
}

export interface LogCursor {
  ts: number;
  id: string;
}

function mapRow(row: MessageRow): LogMessage {
  let attachments: ClientMessageAttachment[] = [];
  try {
    const parsed = row.attachments_json ? JSON.parse(row.attachments_json) : [];
    if (Array.isArray(parsed)) attachments = parsed as ClientMessageAttachment[];
  } catch {}
  return {
    id: row.id,
    sender: row.sender,
    senderName: row.sender_name,
    kind: row.kind,
    type: row.type,
    text: row.text,
    url: row.url,
    attachments,
    ts: row.ts,
  };
}

export function imageUrls(message: Pick<LogMessage, "type" | "url" | "attachments">): string[] {
  if (message.type !== "image") return [];
  const photos = message.attachments
    .filter((item) => item.role === "photo" && item.url)
    .sort((a, b) => a.order - b.order)
    .map((item) => item.url);
  const urls = photos.length ? photos : message.url ? [message.url] : [];
  return [...new Set(urls)].slice(0, 9);
}

/** 找到最近一组连续图片消息，保留每条消息内的多附件顺序。 */
export function latestImageGroup(messages: LogMessage[], maxImages = 9): { messages: LogMessage[]; urls: string[] } {
  const selected: LogMessage[] = [];
  const urls: string[] = [];
  let collecting = false;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const current = imageUrls(messages[index]);
    if (!current.length) {
      if (collecting) break;
      continue;
    }
    collecting = true;
    selected.unshift(messages[index]);
    urls.unshift(...current);
    if (urls.length >= maxImages) break;
  }
  return { messages: selected, urls: urls.slice(-Math.max(1, Math.min(9, maxImages))) };
}

// 最近 N 条消息，按时间正序返回。
export async function recentMessages(storedChannel: string, limit: number): Promise<LogMessage[]> {
  const rows = await all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? ORDER BY ts DESC LIMIT ?",
    [storedChannel, limit],
  );
  return rows.reverse().map(mapRow);
}

// 最近 N 条真实对话消息，忽略系统事件，并可排除正在处理的当前消息。
export async function recentConversationMessages(
  storedChannel: string,
  limit: number,
  excludeMessageId?: string,
): Promise<LogMessage[]> {
  const rows = await all<MessageRow>(
    `SELECT * FROM messages
     WHERE channel = ? AND kind <> 'system'${excludeMessageId ? " AND id <> ?" : ""}
     ORDER BY ts DESC, id DESC LIMIT ?`,
    excludeMessageId
      ? [storedChannel, excludeMessageId, limit]
      : [storedChannel, limit],
  );
  return rows.reverse().map(mapRow);
}

export async function messagesAfter(storedChannel: string, cursor: LogCursor, limit: number): Promise<LogMessage[]> {
  const rows = await all<MessageRow>(
    `SELECT * FROM messages
     WHERE channel = ? AND (ts > ? OR (ts = ? AND id > ?))
     ORDER BY ts ASC, id ASC LIMIT ?`,
    [storedChannel, cursor.ts, cursor.ts, cursor.id, limit],
  );
  return rows.map(mapRow);
}

export async function ownerTextMessagesAfter(
  storedChannel: string,
  cursor: LogCursor,
  limit: number,
  conversationId?: string,
): Promise<LogMessage[]> {
  const rows = await all<MessageRow>(
    `SELECT * FROM messages
     WHERE ${conversationId ? "conversation_id" : "channel"} = ?
       AND (ts > ? OR (ts = ? AND id > ?))
       AND kind = 'user' AND sender <> 'ai' AND type = 'text' AND BTRIM(text) <> ''
     ORDER BY ts ASC, id ASC LIMIT ?`,
    [conversationId ?? storedChannel, cursor.ts, cursor.ts, cursor.id, limit],
  );
  return rows.map(mapRow);
}

/**
 * 读取某个时间点附近的少量共同聊天原文，供日记从总览回到真实语气与顺序。
 * 调用方必须同时给出作息日起止边界；这里只返回主人消息，不含系统事件或大橘发言。
 */
export async function ownerConversationMessagesAround(
  storedChannel: string,
  anchorTs: number,
  rangeStart: number,
  rangeEnd: number,
  limit: number,
): Promise<LogMessage[]> {
  const rows = await all<MessageRow>(
    `SELECT * FROM (
       SELECT * FROM messages
       WHERE channel = ? AND ts >= ? AND ts < ?
         AND kind = 'user' AND sender <> 'ai'
       ORDER BY ABS(ts - ?) ASC, ts ASC, id ASC
       LIMIT ?
     ) AS nearby_messages
     ORDER BY ts ASC, id ASC`,
    [storedChannel, rangeStart, rangeEnd, anchorTs, Math.max(1, Math.min(20, limit))],
  );
  return rows.map(mapRow);
}

function bodyOf(m: LogMessage): string {
  if (m.type === "image") {
    const count = imageUrls(m).length;
    return count > 1 ? `[${count}张图片]` : "[图片]";
  }
  if (m.type === "video") return "[视频]";
  if (m.type === "voice") return "[语音]";
  if (m.type === "sticker") return "[表情]";
  return m.text.replace(/\s+/g, " ").trim();
}

export function compactLine(m: LogMessage, maxLen: number = CONTEXT.lineMax): string {
  const body = bodyOf(m);
  if (!body || m.kind === "system") return "";
  return `${beijingClock(m.ts)} ${m.senderName}: ${body.slice(0, maxLen)}`;
}

export function compactLines(messages: LogMessage[], maxLen: number = CONTEXT.lineMax): string {
  return messages
    .map((m) => compactLine(m, maxLen))
    .filter(Boolean)
    .join("\n");
}
