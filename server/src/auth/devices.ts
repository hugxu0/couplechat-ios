import crypto from "node:crypto";
import { nanoid } from "nanoid";
import { all, get, run, transaction } from "../db";
import type { AuthUser } from "../types";

export interface DeviceRegistrationInput {
  installationId: string;
  platform: "ios" | "ipados";
  deviceName: string;
  appVersion: string;
  buildNumber: string;
  locale: string;
  timezone: string;
}

export interface CurrentDeviceInput extends DeviceRegistrationInput {
  barkKey: string | null;
}

interface DeviceRow {
  id: string;
  account_id: string;
  installation_id: string;
  platform: string;
  device_name: string;
  app_version: string;
  build_number: string;
  protocol_version: number;
  last_seen_at: number;
  revoked_at: number | null;
  created_at: number;
}

function fingerprint(value: string): string {
  // PostgreSQL migration/backfill can reproduce md5() without an extension. This is an
  // opaque stable identity/dedupe key, not a password hash.
  return crypto.createHash("md5").update(value).digest("hex");
}

function deviceValues(input: DeviceRegistrationInput, now: number) {
  return [input.platform, input.deviceName, input.appVersion, input.buildNumber,
    input.locale, input.timezone, now] as const;
}

/** 密码登录是显式授权点：创建/恢复 installation，并签发绑定该设备的 session。 */
export async function createDeviceSession(user: AuthUser, input: DeviceRegistrationInput): Promise<AuthUser | null> {
  if (!user.accountId) return null;
  return transaction(async (db) => {
    const account = await db.get<{ id: string; status: string }>(
      "SELECT id, status FROM accounts WHERE id = ? FOR UPDATE",
      [user.accountId],
    );
    if (account?.status !== "active") return null;
    const now = Date.now();
    let device = await db.get<DeviceRow>(
      "SELECT * FROM devices WHERE account_id = ? AND installation_id = ? FOR UPDATE",
      [account.id, input.installationId],
    );
    if (!device) {
      const id = `dev_${nanoid(16)}`;
      await db.run(
        `INSERT INTO devices
         (id, account_id, installation_id, platform, device_name, app_version,
          build_number, protocol_version, locale, timezone, last_seen_at, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 2, ?, ?, ?, ?)`,
        [id, account.id, input.installationId, input.platform, input.deviceName,
          input.appVersion, input.buildNumber, input.locale, input.timezone, now, now],
      );
      device = await db.get<DeviceRow>("SELECT * FROM devices WHERE id = ?", [id]);
    } else {
      await db.run(
        `UPDATE devices SET platform = ?, device_name = ?, app_version = ?, build_number = ?,
         protocol_version = 2, locale = ?, timezone = ?, last_seen_at = ?, revoked_at = NULL
         WHERE id = ?`,
        [...deviceValues(input, now), device.id],
      );
    }
    if (!device) return null;

    // 同一 installation 再登录会使旧 access token 立即失效，不影响账号的其他设备。
    await db.run(
      "UPDATE auth_sessions SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL",
      [now, device.id],
    );
    const sessionId = `ses_${nanoid(20)}`;
    const tokenVersion = 1;
    const expiresAt = now + 90 * 24 * 60 * 60 * 1_000;
    await db.run(
      `INSERT INTO auth_sessions
       (id, account_id, device_id, refresh_token_hash, token_version,
        created_at, last_seen_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [sessionId, account.id, device.id,
        crypto.createHash("sha256").update(nanoid(48)).digest("hex"),
        tokenVersion, now, now, expiresAt],
    );
    return {
      ...user,
      accountId: account.id,
      deviceId: device.id,
      sessionId,
      tokenVersion,
    };
  });
}

export async function saveCurrentDeviceBark(user: AuthUser, input: CurrentDeviceInput) {
  if (!user.accountId || !user.deviceId || !user.sessionId) return null;
  return transaction(async (db) => {
    const now = Date.now();
    const device = await db.get<DeviceRow>(
      `SELECT device.* FROM devices device
       JOIN auth_sessions session ON session.device_id = device.id
        AND session.id = ? AND session.revoked_at IS NULL AND session.expires_at > ?
       WHERE device.id = ? AND device.account_id = ? AND device.installation_id = ?
         AND device.revoked_at IS NULL FOR UPDATE`,
      [user.sessionId, now, user.deviceId, user.accountId, input.installationId],
    );
    if (!device) return null;
    await db.run(
      `UPDATE devices SET platform = ?, device_name = ?, app_version = ?, build_number = ?,
       protocol_version = 2, locale = ?, timezone = ?, last_seen_at = ? WHERE id = ?`,
      [...deviceValues(input, now), device.id],
    );

    if (input.barkKey) {
      await db.run(
        `INSERT INTO device_push_endpoints
         (id, device_id, provider, secret_value, endpoint_fingerprint, enabled, created_at, updated_at)
         VALUES (?, ?, 'bark', ?, ?, TRUE, ?, ?)
         ON CONFLICT(device_id, provider) DO UPDATE SET
           secret_value = excluded.secret_value,
           endpoint_fingerprint = excluded.endpoint_fingerprint,
           enabled = TRUE, failure_count = 0, disabled_at = NULL,
           updated_at = excluded.updated_at`,
        [`push_${nanoid(16)}`, device.id, input.barkKey, fingerprint(input.barkKey), now, now],
      );
    } else {
      await db.run(
        `UPDATE device_push_endpoints SET enabled = FALSE, disabled_at = ?, updated_at = ?
         WHERE device_id = ? AND provider = 'bark'`,
        [now, now, device.id],
      );
    }

    const fallback = await db.get<{ secret_value: string }>(
      `SELECT endpoint.secret_value FROM device_push_endpoints endpoint
       JOIN devices candidate ON candidate.id = endpoint.device_id
       WHERE candidate.account_id = ? AND candidate.revoked_at IS NULL
         AND endpoint.provider = 'bark' AND endpoint.enabled = TRUE
       ORDER BY endpoint.updated_at DESC, endpoint.id ASC LIMIT 1`,
      [user.accountId],
    );
    await db.run(
      "UPDATE accounts SET bark_key = ?, updated_at = ? WHERE id = ?",
      [fallback?.secret_value ?? null, now, user.accountId],
    );
    return { id: device.id, barkEnabled: Boolean(input.barkKey) };
  });
}

export async function currentDeviceBarkKey(user: AuthUser): Promise<string | null> {
  if (!user.deviceId || !user.accountId) return null;
  const endpoint = await get<{ secret_value: string }>(
    `SELECT endpoint.secret_value FROM device_push_endpoints endpoint
     JOIN devices device ON device.id = endpoint.device_id
     WHERE device.id = ? AND device.account_id = ? AND device.revoked_at IS NULL
       AND endpoint.provider = 'bark' AND endpoint.enabled = TRUE`,
    [user.deviceId, user.accountId],
  );
  return endpoint?.secret_value ?? null;
}

export async function listDevices(user: AuthUser) {
  const accountId = user.accountId ?? (await get<{ id: string }>(
    "SELECT id FROM accounts WHERE username = ? AND status = 'active'", [user.username],
  ))?.id;
  if (!accountId) return [];
  const rows = await all<DeviceRow & { bark_enabled: boolean }>(
    `SELECT device.*,
       COALESCE(BOOL_OR(endpoint.enabled) FILTER (WHERE endpoint.provider = 'bark'), FALSE) AS bark_enabled
     FROM devices device
     LEFT JOIN device_push_endpoints endpoint ON endpoint.device_id = device.id
     WHERE device.account_id = ? AND device.revoked_at IS NULL
     GROUP BY device.id ORDER BY device.last_seen_at DESC`,
    [accountId],
  );
  return rows.map((row) => ({
    id: row.id,
    installationId: row.installation_id,
    platform: row.platform,
    deviceName: row.device_name,
    appVersion: row.app_version,
    buildNumber: row.build_number,
    protocolVersion: row.protocol_version,
    barkEnabled: row.bark_enabled,
    lastSeenAt: row.last_seen_at,
  }));
}

export async function touchCurrentDevice(user: AuthUser, now = Date.now()): Promise<void> {
  if (!user.accountId || !user.deviceId || !user.sessionId) return;
  await Promise.all([
    run(
      `UPDATE devices SET last_seen_at = ?
       WHERE id = ? AND account_id = ? AND revoked_at IS NULL`,
      [now, user.deviceId, user.accountId],
    ),
    run(
      `UPDATE auth_sessions SET last_seen_at = ?
       WHERE id = ? AND device_id = ? AND revoked_at IS NULL`,
      [now, user.sessionId, user.deviceId],
    ),
  ]);
}

export async function revokeDevice(user: AuthUser, deviceId: string): Promise<boolean> {
  const accountId = user.accountId ?? (await get<{ id: string }>(
    "SELECT id FROM accounts WHERE username = ? AND status = 'active'", [user.username],
  ))?.id;
  if (!accountId) return false;
  return transaction(async (db) => {
    const now = Date.now();
    const changed = await db.run(
      "UPDATE devices SET revoked_at = ? WHERE id = ? AND account_id = ? AND revoked_at IS NULL",
      [now, deviceId, accountId],
    );
    if (!changed) return false;
    await db.run(
      "UPDATE auth_sessions SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL",
      [now, deviceId],
    );
    await db.run(
      `UPDATE device_push_endpoints SET enabled = FALSE, disabled_at = ?, updated_at = ?
       WHERE device_id = ?`,
      [now, now, deviceId],
    );
    const fallback = await db.get<{ secret_value: string }>(
      `SELECT endpoint.secret_value FROM device_push_endpoints endpoint
       JOIN devices device ON device.id = endpoint.device_id
       WHERE device.account_id = ? AND device.revoked_at IS NULL
         AND endpoint.provider = 'bark' AND endpoint.enabled = TRUE
       ORDER BY endpoint.updated_at DESC, endpoint.id ASC LIMIT 1`,
      [accountId],
    );
    await db.run(
      "UPDATE accounts SET bark_key = ?, updated_at = ? WHERE id = ?",
      [fallback?.secret_value ?? null, now, accountId],
    );
    return true;
  });
}
