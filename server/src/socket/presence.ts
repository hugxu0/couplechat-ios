import type { Server } from "socket.io";
import { socketEvents } from "../contracts/realtime";
import type { AuthUser } from "../types";

// availability 属于具体连接，而不是账号。iPad 退到后台时，只要同账号的 iPhone
// 仍在前台，就仍应保持在线且不能误发 Bark。
const socketsByUser = new Map<string, Map<string, boolean>>();
const coupleByUser = new Map<string, string>();

export function markConnected(user: AuthUser, socketId: string) {
  const sockets = socketsByUser.get(user.username) ?? new Map<string, boolean>();
  sockets.set(socketId, false);
  socketsByUser.set(user.username, sockets);
  if (user.coupleId) coupleByUser.set(user.username, user.coupleId);
}

export function markDisconnected(user: AuthUser, socketId: string) {
  const sockets = socketsByUser.get(user.username);
  if (!sockets) return;
  sockets.delete(socketId);
  if (sockets.size === 0) {
    socketsByUser.delete(user.username);
    coupleByUser.delete(user.username);
  }
}

export function setAway(user: AuthUser, socketId: string, away: boolean) {
  const sockets = socketsByUser.get(user.username);
  if (sockets?.has(socketId)) sockets.set(socketId, away);
}

export function isAvailable(username: string) {
  return [...(socketsByUser.get(username)?.values() ?? [])].some((away) => !away);
}

export function onlineUsers(coupleId: string) {
  return [...socketsByUser.keys()].filter((username) =>
    coupleByUser.get(username) === coupleId && isAvailable(username));
}

export function broadcastPresence(io: Server, coupleId?: string) {
  if (!coupleId) return;
  io.to(`couple:${coupleId}`).emit(socketEvents.presence, { online: onlineUsers(coupleId) });
}

export function resetPresenceForTests() {
  socketsByUser.clear();
  coupleByUser.clear();
}
