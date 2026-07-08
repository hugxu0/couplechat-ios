export type Username = string;

export type ClientChannel = "couple" | "ai";
export type StoredChannel = "couple" | `ai:${Username}`;

export type MessageType = "text" | "image" | "video" | "sticker" | "voice" | "file";
export type MessageKind = "user" | "system";

export interface AuthUser {
  username: string;
  name: string;
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
  reply?: unknown;
  meta?: unknown;
  channel: ClientChannel;
  ts: number;
  clientId?: string;
}

export function toStoredChannel(channel: ClientChannel, user: Username): StoredChannel {
  return channel === "ai" ? `ai:${user}` : "couple";
}

export function toClientChannel(channel: StoredChannel): ClientChannel {
  return channel.startsWith("ai:") ? "ai" : "couple";
}
