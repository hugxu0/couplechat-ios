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
  aiActivity: "ai:activity",
  personalItemChanged: "personalItem:changed",
} as const;

export const clientChannelSchema = z.enum(["couple", "ai"]);

const messageAttachmentSchema = z.object({
  assetId: z.string().min(1).max(64).regex(/^[A-Za-z0-9_-]+$/),
  role: z.enum(["photo", "pairedVideo"]),
  uploadId: z.string().regex(/^up_[A-Za-z0-9_-]{8,}$/),
  order: z.number().int().min(0).max(8),
});

const interactionSchema = z.object({
  id: z.string().min(1).max(64),
  kind: z.enum(["miss", "pat", "flower", "poop", "note"]),
  text: z.string().max(200),
});

const messageMetaSchema = z.object({
  interaction: interactionSchema.optional(),
}).passthrough();

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
  meta: messageMetaSchema.optional(),
  attachments: z.array(messageAttachmentSchema).min(1).max(18).optional(),
  clientId: z.string().min(1).max(128).optional(),
}).superRefine((value, ctx) => {
  const hasAttachments = Boolean(value.attachments?.length);
  const requiresUpload = ["image", "video", "voice", "file"].includes(value.type) && !hasAttachments;
  if (hasAttachments) {
    if (value.type !== "image") {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["attachments"], message: "attachments_require_image_type" });
    }
    if (value.uploadId) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["uploadId"], message: "legacy_upload_conflicts_with_attachments" });
    }
    const assets = new Map<string, Set<string>>();
    const uploadIds = new Set<string>();
    for (const attachment of value.attachments ?? []) {
      const roles = assets.get(attachment.assetId) ?? new Set<string>();
      roles.add(attachment.role);
      assets.set(attachment.assetId, roles);
      if (uploadIds.has(attachment.uploadId)) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["attachments"], message: "duplicate_upload_reference" });
      }
      uploadIds.add(attachment.uploadId);
    }
    if (assets.size < 1 || assets.size > 9) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["attachments"], message: "asset_count_out_of_range" });
    }
    for (const roles of assets.values()) {
      if (!roles.has("photo") || roles.size > 2) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["attachments"], message: "invalid_live_photo_pair" });
      }
    }
  }
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
  // 原生共享状态统一为 JSON 对象，避免旧客户端写入顶层标量后破坏启动同步。
  value: z.record(z.string(), z.unknown()),
});

export const recallMessageSchema = z.object({
  id: z.string().min(1),
});

export const confirmActionSchema = z.object({
  messageId: z.string().min(1),
  decision: z.enum(["confirm", "cancel"]),
});

export type SendMessagePayload = z.infer<typeof sendMessageSchema>;
