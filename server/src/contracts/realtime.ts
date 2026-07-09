import { z } from "zod";

/**
 * Socket.IO 的单一协议定义。
 *
 * 服务端路由、服务层和冒烟测试都应从这里导入事件名、payload schema 与推导类型，
 * 避免客户端/服务端各自维护字段时再次出现 `after` / `since` 这样的静默漂移。
 */
export const socketEvents = {
  health: "health",
  away: "away",
  presence: "presence",
  messageSend: "message:send",
  messageNew: "message:new",
  messageRecall: "message:recall",
  messageRecalled: "message:recalled",
  messageUpdate: "message:update",
  messagesFetch: "messages:fetch",
  messagesSearch: "messages:search",
  read: "read",
  readInit: "read:init",
  readUpdate: "read:update",
  sharedInit: "shared:init",
  sharedSet: "shared:set",
  sharedUpdate: "shared:update",
  actionConfirm: "action:confirm",
  aiTyping: "ai:typing",
  aiReplying: "ai:replying",
  personalItemChanged: "personalItem:changed",
} as const;

export const clientChannelSchema = z.enum(["couple", "ai"]);

export const sendMessageSchema = z.object({
  channel: clientChannelSchema.default("couple"),
  type: z.enum(["text", "image", "video", "sticker", "voice", "file"]).default("text"),
  text: z.string().default(""),
  url: z.string().url().optional(),
  replyTo: z.string().min(1).optional(),
  replyPreview: z.string().optional(),
  reply: z.unknown().optional(),
  meta: z.unknown().optional(),
  clientId: z.string().min(1).optional(),
});

export const fetchMessagesSchema = z.object({
  channel: clientChannelSchema.default("couple"),
  since: z.number().optional(),
  after: z.number().optional(),
  before: z.number().optional(),
  around: z.number().optional(),
  limit: z.number().int().min(1).max(300).optional(),
});

export const readReceiptSchema = z.object({
  channel: clientChannelSchema.default("couple"),
  ts: z.number().positive(),
});

export const searchMessagesSchema = z.object({
  channel: clientChannelSchema.default("couple"),
  query: z.string().min(1),
  limit: z.number().int().min(1).max(100).optional(),
});

export const sharedSetSchema = z.object({
  key: z.string().min(1).max(80).regex(/^[a-zA-Z0-9:_-]+$/),
  value: z.unknown(),
});

export const recallMessageSchema = z.object({
  id: z.string().min(1),
});

export const confirmActionSchema = z.object({
  messageId: z.string().min(1),
  decision: z.enum(["confirm", "cancel"]),
});

export type SendMessagePayload = z.infer<typeof sendMessageSchema>;
export type FetchMessagesPayload = z.infer<typeof fetchMessagesSchema>;
export type ReadReceiptPayload = z.infer<typeof readReceiptSchema>;
