import type { Server } from "socket.io";
import { socketEvents } from "../contracts/realtime";
import type { AuthUser } from "../types";

const socketsByUser = new Map<string, Set<string>>();
const awayByUser = new Map<string, boolean>();

export function markConnected(user: AuthUser, socketId: string) {
  const sockets = socketsByUser.get(user.username) ?? new Set<string>();
  sockets.add(socketId);
  socketsByUser.set(user.username, sockets);
  awayByUser.set(user.username, false);
}

export function markDisconnected(user: AuthUser, socketId: string) {
  const sockets = socketsByUser.get(user.username);
  if (!sockets) return;
  sockets.delete(socketId);
  if (sockets.size === 0) {
    socketsByUser.delete(user.username);
    awayByUser.set(user.username, true);
  }
}

export function setAway(user: AuthUser, away: boolean) {
  awayByUser.set(user.username, away);
}

export function isAvailable(username: string) {
  return (socketsByUser.get(username)?.size ?? 0) > 0 && awayByUser.get(username) !== true;
}

export function onlineUsers() {
  return [...socketsByUser.keys()].filter((username) => isAvailable(username));
}

export function broadcastPresence(io: Server) {
  io.to("channel:couple").emit(socketEvents.presence, { online: onlineUsers() });
}
