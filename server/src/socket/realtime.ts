import type { Server, Socket } from "socket.io";
import { verifyToken } from "../auth/token";
import type { AuthUser, ClientChannel } from "../types";
import {
  confirmActionSchema,
  fetchMessagesSchema,
  readReceiptSchema,
  recallMessageSchema,
  searchMessagesSchema,
  sendMessageSchema,
  sharedSetSchema,
  socketEvents,
} from "../contracts/realtime";
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

    socket.emit(socketEvents.readInit, {
      channel: "couple",
      state: await getReadReceipts(user, "couple"),
    });
    socket.emit(socketEvents.sharedInit, await getSharedState());

    socket.on("disconnect", () => {
      markDisconnected(user, socket.id);
      broadcastPresence(io);
    });

    socket.on(socketEvents.health, (ack?: Ack) => {
      ack?.({ ok: true, ts: Date.now() });
    });

    socket.on(socketEvents.away, (away: boolean) => {
      setAway(user, Boolean(away));
      broadcastPresence(io);
    });

    socket.on(socketEvents.messagesFetch, (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = fetchMessagesSchema.parse(payload ?? {});
        const list = await fetchMessages(user, input);
        return { ok: true, list, replace: !input.since && !input.after && !input.before };
      }, ack),
    );

    socket.on(socketEvents.messagesSearch, (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = searchMessagesSchema.parse(payload ?? {});
        const list = await searchMessages(user, input.channel, input.query, input.limit);
        return { ok: true, list };
      }, ack),
    );

    socket.on(socketEvents.messageSend, (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = sendMessageSchema.parse(payload ?? {});
        const message = await createMessage(user, input);
        io.to(roomFor(input.channel, user)).emit(socketEvents.messageNew, message);

        if (input.channel === "couple") {
          void pushCoupleMessageToUnavailableRecipients(message);
        }
        // AI 流水线（couple 召唤应答 / ai 私聊应答 / 记忆提取 / 滚动摘要）
        handleUserMessage(io, user, message);

        return { ok: true, id: message.id };
      }, ack),
    );

    socket.on(socketEvents.messageRecall, (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = recallMessageSchema.parse(payload ?? {});
        const recalled = await recallMessage(user, input.id);
        if (!recalled) return { ok: false, error: "not_found" };
        io.to(roomFor(recalled.channel, user)).emit(socketEvents.messageRecalled, recalled);
        return { ok: true };
      }, ack),
    );

    socket.on(socketEvents.read, (payload: unknown) => {
      const parsed = readReceiptSchema.safeParse(payload ?? {});
      if (!parsed.success) return;
      void upsertReadReceipt(user, parsed.data.channel, parsed.data.ts).then(() => {
        io.to(roomFor(parsed.data.channel, user)).emit(socketEvents.readUpdate, {
          channel: parsed.data.channel,
          user: user.username,
          ts: parsed.data.ts,
        });
      });
    });

    socket.on(socketEvents.sharedInit, (_payload?: unknown, ack?: Ack) =>
      safeAck(async () => ({ ok: true, state: await getSharedState() }), ack),
    );

    socket.on(socketEvents.sharedSet, (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = sharedSetSchema.parse(payload ?? {});
        const update = await setSharedItem(user, input.key, input.value);
        io.to("channel:couple").emit(socketEvents.sharedUpdate, update);
        return { ok: true, update };
      }, ack),
    );

    socket.on(socketEvents.actionConfirm, (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = confirmActionSchema.parse(payload ?? {});
        const result = await confirmAction(io, input.messageId, input.decision);
        return result;
      }, ack),
    );
  });
}
