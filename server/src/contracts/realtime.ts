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
  messagesSearch: "messages:search",
  read: "read",
  readUpdate: "read:update",
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
  text: z.string().max(8_000).default(""),
  // url 仅用于交叉校验；服务端最终使用 uploadId 对应记录中的 URL。
  url: z.string().url().max(2_000).optional(),
  uploadId: z.string().regex(/^up_[A-Za-z0-9_-]{8,}$/).optional(),
  replyTo: z.string().min(1).max(128).optional(),
  replyPreview: z.string().max(500).optional(),
  reply: z.unknown().optional(),
  meta: z.unknown().optional(),
  clientId: z.string().min(1).max(128).optional(),
}).superRefine((value, ctx) => {
  const requiresUpload = ["image", "video", "voice", "file"].includes(value.type);
  if (requiresUpload && !value.uploadId) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["uploadId"], message: "upload_reference_required" });
  }
  if (!requiresUpload && value.uploadId) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["uploadId"], message: "upload_reference_not_allowed" });
  }
});

export const readReceiptSchema = z.object({
  channel: clientChannelSchema.default("couple"),
  // Swift 的 Date.timeIntervalSince1970 * 1000 可能带小数；PostgreSQL BIGINT
  // 只能存整数毫秒。入口统一四舍五入，兼容已发布客户端并保持协议稳定。
  ts: z.number().finite().positive().transform((value) => Math.round(value)),
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
export type ReadReceiptPayload = z.infer<typeof readReceiptSchema>;
