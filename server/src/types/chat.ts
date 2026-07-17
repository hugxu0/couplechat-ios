import type { Username } from "./auth";

export type ClientChannel = "couple" | "ai";
export type StoredChannel = "couple" | `ai:${Username}`;

export type MessageType = "text" | "image" | "video" | "sticker" | "voice" | "file";
export type MessageKind = "user" | "system";
export type MessageAttachmentRole = "photo" | "pairedVideo";

export interface ClientMessageAttachment {
  id: string;
  assetId: string;
  role: MessageAttachmentRole;
  order: number;
  url: string;
  mimeType: string;
  size: number;
}

export interface ClientMessage {
  id: string;
  sender: string;
  senderName: string;
  kind: MessageKind;
  type: MessageType;
  text: string;
  url?: string;
  replyTo?: string;
  replyPreview?: string;
  meta?: unknown;
  attachments?: ClientMessageAttachment[];
  recalledText?: string;
  channel: ClientChannel;
  ts: number;
  clientId?: string;
  transcript?: {
    status: "pending" | "processing" | "completed" | "failed" | "unavailable";
    text: string;
    rawText?: string;
    corrected: boolean;
    language?: string;
    version: number;
  };
}

export function toStoredChannel(channel: ClientChannel, user: Username): StoredChannel {
  return channel === "ai" ? `ai:${user}` : "couple";
}

export function toClientChannel(channel: StoredChannel): ClientChannel {
  return channel.startsWith("ai:") ? "ai" : "couple";
}
