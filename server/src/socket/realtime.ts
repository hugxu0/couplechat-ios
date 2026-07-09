import type { Server, Socket } from "socket.io";
import { z } from "zod";
import { verifyToken } from "../auth/token";
import type { AuthUser, ClientChannel } from "../types";
import {
  createMessage,
  fetchMessages,
  getReadReceipts,
  recallMessage,
  searchMessages,
  upsertReadReceipt,
} from "../chat/messageService";
import { handleUserMessage } from "../ai/aiService";
import { confirmAction } from "../ai/actionService";
import { getSharedState, setSharedItem } from "../shared/sharedService";
import {
  broadcastPresence,
  markConnected,
  markDisconnected,
  setAway,
} from "./presence";
import { pushCoupleMessageToUnavailableRecipients } from "../push/pushService";

type Ack = (value: unknown) => void;

const channelSchema = z.enum(["couple", "ai"]).default("couple");

const sendMessageSchema = z.object({
  channel: channelSchema,
  type: z.enum(["text", "image", "video", "sticker", "voice", "file"]).default("text"),
  text: z.string().default(""),
  url: z.string().url().optional(),
  replyTo: z.string().min(1).optional(),
  replyPreview: z.string().optional(),
  reply: z.unknown().optional(),
  meta: z.unknown().optional(),
  clientId: z.string().min(1).optional(),
});

const fetchSchema = z.object({
  channel: channelSchema,
  since: z.number().optional(),
  before: z.number().optional(),
  around: z.number().optional(),
  limit: z.number().int().min(1).max(300).optional(),
});

const readSchema = z.object({
  channel: channelSchema,
  ts: z.number().positive(),
});

const searchSchema = z.object({
  channel: channelSchema,
  query: z.string().min(1),
  limit: z.number().int().min(1).max(100).optional(),
});

const sharedSetSchema = z.object({
  key: z.string().min(1).max(80).regex(/^[a-zA-Z0-9:_-]+$/),
  value: z.unknown(),
});

const recallSchema = z.object({
  id: z.string().min(1),
});

const confirmActionSchema = z.object({
  messageId: z.string().min(1),
  decision: z.enum(["confirm", "cancel"]),
});

function userFrom(socket: Socket): AuthUser {
  return socket.data.user as AuthUser;
}

function roomFor(channel: ClientChannel, user: AuthUser) {
  return channel === "ai" ? `user:${user.username}` : "channel:couple";
}

async function safeAck(fn: () => Promise<unknown>, ack?: Ack) {
  try {
    const result = await fn();
    ack?.(result);
  } catch (error) {
    ack?.({ ok: false, error: error instanceof Error ? error.message : "unknown_error" });
  }
}

export function registerRealtime(io: Server) {
  io.use((socket, next) => {
    const token = socket.handshake.auth?.token ?? socket.handshake.query?.token;
    const user = typeof token === "string" ? verifyToken(token) : null;
    if (!user) return next(new Error("unauthorized"));
    socket.data.user = user;
    next();
  });

  io.on("connection", async (socket) => {
    const user = userFrom(socket);
    socket.join("channel:couple");
    socket.join(`user:${user.username}`);

    markConnected(user, socket.id);
    broadcastPresence(io);

    socket.emit("read:init", {
      channel: "couple",
      state: await getReadReceipts(user, "couple"),
    });
    socket.emit("shared:init", await getSharedState());

    socket.on("disconnect", () => {
      markDisconnected(user, socket.id);
      broadcastPresence(io);
    });

    socket.on("health", (ack?: Ack) => {
      ack?.({ ok: true, ts: Date.now() });
    });

    socket.on("away", (away: boolean) => {
      setAway(user, Boolean(away));
      broadcastPresence(io);
    });

    socket.on("messages:fetch", (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = fetchSchema.parse(payload ?? {});
        const list = await fetchMessages(user, input);
        return { ok: true, list, replace: !input.since && !input.before };
      }, ack),
    );

    socket.on("messages:search", (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = searchSchema.parse(payload ?? {});
        const list = await searchMessages(user, input.channel, input.query, input.limit);
        return { ok: true, list };
      }, ack),
    );

    socket.on("message:send", (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = sendMessageSchema.parse(payload ?? {});
        const message = await createMessage(user, input);
        io.to(roomFor(input.channel, user)).emit("message:new", message);

        if (input.channel === "couple") {
          void pushCoupleMessageToUnavailableRecipients(message);
        }
        // AI 流水线（couple 召唤应答 / ai 私聊应答 / 记忆提取 / 滚动摘要）
        handleUserMessage(io, user, message);

        return { ok: true, id: message.id };
      }, ack),
    );

    socket.on("message:recall", (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = recallSchema.parse(payload ?? {});
        const recalled = await recallMessage(user, input.id);
        if (!recalled) return { ok: false, error: "not_found" };
        io.to(roomFor(recalled.channel, user)).emit("message:recalled", recalled);
        return { ok: true };
      }, ack),
    );

    socket.on("read", (payload: unknown) => {
      const parsed = readSchema.safeParse(payload ?? {});
      if (!parsed.success) return;
      void upsertReadReceipt(user, parsed.data.channel, parsed.data.ts).then(() => {
        io.to(roomFor(parsed.data.channel, user)).emit("read:update", {
          channel: parsed.data.channel,
          user: user.username,
          ts: parsed.data.ts,
        });
      });
    });

    socket.on("shared:init", (_payload?: unknown, ack?: Ack) =>
      safeAck(async () => ({ ok: true, state: await getSharedState() }), ack),
    );

    socket.on("shared:set", (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = sharedSetSchema.parse(payload ?? {});
        const update = await setSharedItem(user, input.key, input.value);
        io.to("channel:couple").emit("shared:update", update);
        return { ok: true, update };
      }, ack),
    );

    socket.on("action:confirm", (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = confirmActionSchema.parse(payload ?? {});
        const result = await confirmAction(io, input.messageId, input.decision);
        return result;
      }, ack),
    );
  });
}
