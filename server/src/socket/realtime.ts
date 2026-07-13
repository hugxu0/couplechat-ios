import type { Server, Socket } from "socket.io";
import { verifyActiveToken } from "../auth/token";
import type { AuthUser, ClientChannel } from "../types";
import {
  confirmActionSchema,
  readReceiptSchema,
  recallMessageSchema,
  searchMessagesSchema,
  sendMessageSchema,
  sharedSetSchema,
  socketEvents,
} from "../contracts/realtime";
import {
  searchMessages,
  upsertReadReceipt,
} from "../chat/messageService";
import { confirmAction } from "../ai/actions/personalItems";
import { setSharedItem } from "../shared/sharedService";
import {
  broadcastPresence,
  markConnected,
  markDisconnected,
  setAway,
} from "./presence";
import { createRealtimeMessageUseCases } from "../chat/realtimeUseCases";
import { nanoid } from "nanoid";
import { errorCodeFor, errorCodes } from "../errors/errorCodes";
import { touchCurrentDevice } from "../auth/devices";

type Ack = (value: unknown) => void;
const socketsByDevice = new Map<string, Set<Socket>>();

export function disconnectDeviceSockets(deviceId: string): void {
  const sockets = socketsByDevice.get(deviceId);
  if (!sockets) return;
  for (const socket of sockets) socket.disconnect(true);
  socketsByDevice.delete(deviceId);
}

function userFrom(socket: Socket): AuthUser {
  return socket.data.user as AuthUser;
}

function roomFor(channel: ClientChannel, user: AuthUser) {
  return channel === "ai" ? `account:${user.accountId ?? user.username}` : `couple:${user.coupleId ?? "unpaired"}`;
}

async function safeAck(fn: () => Promise<unknown>, ack?: Ack) {
  try {
    const result = await fn();
    ack?.(result);
  } catch (error) {
    ack?.({ ok: false, error: errorCodeFor(error) });
  }
}

export function registerRealtime(io: Server) {
  const messages = createRealtimeMessageUseCases(io);
  io.use((socket, next) => {
    // Token 必须走 Socket.IO auth payload，不能落进握手 URL 的 query string，
    // 否则默认的反向代理访问日志可能记录完整 token。
    const token = socket.handshake.auth?.token;
    if (typeof token !== "string") return next(new Error("unauthorized"));
    void verifyActiveToken(token).then((user) => {
      if (!user) return next(new Error("unauthorized"));
      socket.data.user = user;
      next();
    }).catch(() => next(new Error("unauthorized")));
  });

  io.on("connection", (socket) => {
    const user = userFrom(socket);
    void touchCurrentDevice(user).catch((error) => {
      console.warn(`[device] 更新最近活跃时间失败: ${error instanceof Error ? error.message : String(error)}`);
    });
    if (user.deviceId) {
      const deviceSockets = socketsByDevice.get(user.deviceId) ?? new Set<Socket>();
      deviceSockets.add(socket);
      socketsByDevice.set(user.deviceId, deviceSockets);
    }
    if (user.coupleId) socket.join(`couple:${user.coupleId}`);
    socket.join(`account:${user.accountId ?? user.username}`);
    // 兼容仍监听 user:username 的 AI/事项事件，V2 域逐步切到 account:id。
    socket.join(`user:${user.username}`);

    markConnected(user, socket.id);
    broadcastPresence(io, user.coupleId);

    socket.on("disconnect", () => {
      if (user.deviceId) {
        const deviceSockets = socketsByDevice.get(user.deviceId);
        deviceSockets?.delete(socket);
        if (deviceSockets?.size === 0) socketsByDevice.delete(user.deviceId);
      }
      markDisconnected(user, socket.id);
      broadcastPresence(io, user.coupleId);
    });

    socket.on(socketEvents.health, (ack?: Ack) => {
      ack?.({ ok: true, ts: Date.now() });
    });

    socket.on(socketEvents.away, (away: boolean) => {
      setAway(user, socket.id, Boolean(away));
      broadcastPresence(io, user.coupleId);
    });

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
        const requestId = `evt_${nanoid(12)}`;
        const message = await messages.send(user, input, requestId);
        io.to(roomFor(input.channel, user)).emit(socketEvents.messageNew, message);
        return { ok: true, id: message.id, message, requestId };
      }, ack),
    );

    socket.on(socketEvents.messageRecall, (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = recallMessageSchema.parse(payload ?? {});
        const recalled = await messages.recall(user, input.id);
        if (!recalled) return { ok: false, error: errorCodes.notFound };
        io.to(roomFor(recalled.channel, user)).emit(socketEvents.messageRecalled, recalled);
        if (recalled.notice) {
          io.to(roomFor(recalled.channel, user)).emit(socketEvents.messageNew, recalled.notice);
        }
        return { ok: true, notice: recalled.notice };
      }, ack),
    );

    socket.on(socketEvents.read, (payload: unknown) => {
      const parsed = readReceiptSchema.safeParse(payload ?? {});
      if (!parsed.success) return;
      void upsertReadReceipt(user, parsed.data.channel, parsed.data.ts).then((effectiveTs) => {
        io.to(roomFor(parsed.data.channel, user)).emit(socketEvents.readUpdate, {
          channel: parsed.data.channel,
          user: user.username,
          ts: effectiveTs,
        });
      }).catch((error) => {
        console.warn(`[read] 回执写入失败 user=${user.username}: ${error instanceof Error ? error.message : String(error)}`);
      });
    });

    socket.on(socketEvents.sharedSet, (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = sharedSetSchema.parse(payload ?? {});
        const update = await setSharedItem(user, input.key, input.value);
        if (user.coupleId) io.to(`couple:${user.coupleId}`).emit(socketEvents.sharedUpdate, update);
        return { ok: true, update };
      }, ack),
    );

    socket.on(socketEvents.actionConfirm, (payload: unknown, ack?: Ack) =>
      safeAck(async () => {
        const input = confirmActionSchema.parse(payload ?? {});
        const result = await confirmAction(io, user, input.messageId, input.decision);
        return result;
      }, ack),
    );
  });
}
