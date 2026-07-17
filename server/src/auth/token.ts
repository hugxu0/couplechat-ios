import crypto from "node:crypto";
import { config } from "../config";
import type { AuthUser } from "../types";
import { get } from "../db";

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
    const user: AuthUser = { username: payload.username, name: payload.name };
    if (typeof payload.accountId === "string") user.accountId = payload.accountId;
    if (typeof payload.deviceId === "string") user.deviceId = payload.deviceId;
    if (typeof payload.sessionId === "string") user.sessionId = payload.sessionId;
    if (typeof payload.tokenVersion === "number") user.tokenVersion = payload.tokenVersion;
    if (typeof payload.coupleId === "string") user.coupleId = payload.coupleId;
    if (typeof payload.memberId === "string") user.memberId = payload.memberId;
    return user;
  } catch {
    return null;
  }
}

/** 校验签名后再核对账号、设备和 session 状态。当前客户端只使用设备绑定的 session token。 */
export async function verifyActiveToken(token: string): Promise<AuthUser | null> {
  const user = verifyToken(token);
  if (!user) return null;
  if (!user.sessionId || !user.deviceId || !user.accountId || user.tokenVersion === undefined) return null;
  const row = await get<{
    username: string;
    display_name: string;
    token_version: number;
    expires_at: number;
    couple_id: string | null;
    member_id: string | null;
  }>(
    `SELECT account.username, account.display_name, session.token_version, session.expires_at,
            member.couple_id, member.id AS member_id
       FROM auth_sessions session
       JOIN accounts account ON account.id = session.account_id AND account.status = 'active'
       JOIN devices device ON device.id = session.device_id AND device.revoked_at IS NULL
       LEFT JOIN couple_members member ON member.account_id = account.id AND member.state = 'active'
      WHERE session.id = ? AND session.account_id = ? AND session.device_id = ?
        AND session.revoked_at IS NULL`,
    [user.sessionId, user.accountId, user.deviceId],
  );
  if (!row || row.expires_at < Date.now() || row.token_version !== user.tokenVersion) return null;
  return {
    username: row.username,
    name: row.display_name,
    accountId: user.accountId,
    deviceId: user.deviceId,
    sessionId: user.sessionId,
    tokenVersion: user.tokenVersion,
    coupleId: row.couple_id ?? undefined,
    memberId: row.member_id ?? undefined,
  };
}
