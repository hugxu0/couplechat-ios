// 读取聊天记录并压缩为适合模型输入的单行文本。

import { all, type MessageRow } from "../../db";
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
  ts: number;
}

export interface LogCursor {
  ts: number;
  id: string;
}

function mapRow(row: MessageRow): LogMessage {
  return {
    id: row.id,
    sender: row.sender,
    senderName: row.sender_name,
    kind: row.kind,
    type: row.type,
    text: row.text,
    url: row.url,
    ts: row.ts,
  };
}

// 查找最近一条图片消息。
export function latestImage(messages: LogMessage[]): LogMessage | undefined {
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    if (messages[i].type === "image" && messages[i].url) return messages[i];
  }
  return undefined;
}

// 最近 N 条消息，按时间正序返回。
export async function recentMessages(storedChannel: string, limit: number): Promise<LogMessage[]> {
  const rows = await all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? ORDER BY ts DESC LIMIT ?",
    [storedChannel, limit],
  );
  return rows.reverse().map(mapRow);
}

export async function messagesBetween(storedChannel: string, start: number, end: number): Promise<LogMessage[]> {
  const rows = await all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? AND ts >= ? AND ts < ? ORDER BY ts ASC",
    [storedChannel, start, end],
  );
  return rows.map(mapRow);
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

export async function ownerTextMessagesAfter(storedChannel: string, cursor: LogCursor, limit: number): Promise<LogMessage[]> {
  const rows = await all<MessageRow>(
    `SELECT * FROM messages
     WHERE channel = ? AND (ts > ? OR (ts = ? AND id > ?))
       AND kind = 'user' AND sender <> 'ai' AND type = 'text' AND BTRIM(text) <> ''
     ORDER BY ts ASC, id ASC LIMIT ?`,
    [storedChannel, cursor.ts, cursor.ts, cursor.id, limit],
  );
  return rows.map(mapRow);
}

function bodyOf(m: LogMessage): string {
  if (m.type === "image") return "[图片]";
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
