import crypto from "node:crypto";
import { config } from "../config";
import type { AuthUser } from "../types";

interface TokenPayload extends AuthUser {
  exp: number;
}

function encode(value: unknown): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function sign(data: string): string {
  return crypto.createHmac("sha256", config.tokenSecret).update(data).digest("base64url");
}

export function createToken(user: AuthUser, ttlDays = 90): string {
  const payload: TokenPayload = {
    ...user,
    exp: Date.now() + ttlDays * 24 * 60 * 60 * 1000,
  };
  const body = encode(payload);
  return `${body}.${sign(body)}`;
}

export function verifyToken(token: string): AuthUser | null {
  const [body, mac] = token.split(".");
  if (!body || !mac) return null;
  const expected = sign(body);
  if (mac.length !== expected.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(mac), Buffer.from(expected))) return null;

  try {
    const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as TokenPayload;
    if (!payload.username || !payload.name || payload.exp < Date.now()) return null;
    return { username: payload.username, name: payload.name };
  } catch {
    return null;
  }
}
