// AI 侧的聊天记录读取与压缩：直接按存储频道查 messages 表，
// 并把消息压成「HH:MM 名字: 内容」的单行文本喂给模型。

import { all, type MessageRow } from "../db";
import { beijingClock } from "./time";
import { CONTEXT } from "./params";

export interface LogMessage {
  id: string;
  sender: string;
  senderName: string;
  kind: string;
  type: string;
  text: string;
  ts: number;
}

function mapRow(row: MessageRow): LogMessage {
  return {
    id: row.id,
    sender: row.sender,
    senderName: row.sender_name,
    kind: row.kind,
    type: row.type,
    text: row.text,
    ts: row.ts,
  };
}

// 最近 N 条（按时间正序返回）。
export function recentMessages(storedChannel: string, limit: number): LogMessage[] {
  const rows = all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? ORDER BY ts DESC LIMIT ?",
    [storedChannel, limit],
  );
  return rows.reverse().map(mapRow);
}

export function messagesBetween(storedChannel: string, start: number, end: number): LogMessage[] {
  return all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? AND ts >= ? AND ts < ? ORDER BY ts ASC",
    [storedChannel, start, end],
  ).map(mapRow);
}

export function messagesAfter(storedChannel: string, ts: number, limit: number): LogMessage[] {
  return all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? AND ts > ? ORDER BY ts ASC LIMIT ?",
    [storedChannel, ts, limit],
  ).map(mapRow);
}

export function latestTs(storedChannel: string): number {
  const rows = all<MessageRow>(
    "SELECT * FROM messages WHERE channel = ? ORDER BY ts DESC LIMIT 1",
    [storedChannel],
  );
  return rows[0]?.ts ?? 0;
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
