import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("v24 retires non-fixed accounts, revokes their sessions and drops invites", async () => {
  await withTestDatabase(async () => {
    const { databasePool, get, migrate, run } = await import("../../src/db");
    const now = Date.now();
    await run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES ('acc_xu', 'xu', '小旭', 'hash', '', 'active', 0, ?, ?),
              ('acc_old', 'old_user', '旧账号', 'hash', '', 'active', 0, ?, ?)`,
      [now, now, now, now],
    );
    await run(
      `INSERT INTO couples (id, name, status, created_by_account_id, created_at, updated_at, version)
       VALUES ('cpl_old', '旧空间', 'active', 'acc_old', ?, ?, 0)`,
      [now, now],
    );
    await run(
      `INSERT INTO couple_members (id, couple_id, account_id, role, state, joined_at, updated_at)
       VALUES ('mem_old', 'cpl_old', 'acc_old', 'owner', 'active', ?, ?)`,
      [now, now],
    );
    await run(
      `INSERT INTO couple_invites
       (id, couple_id, code_hash, created_by_member_id, expires_at, created_at)
       VALUES ('inv_old', 'cpl_old', 'old_hash', 'mem_old', ?, ?)`,
      [now + 60_000, now],
    );
    await run(
      `INSERT INTO devices
       (id, account_id, installation_id, platform, device_name, protocol_version, last_seen_at, created_at)
       VALUES ('dev_old', 'acc_old', 'installation-old', 'ios', 'iPhone', 2, ?, ?)`,
      [now, now],
    );
    await run(
      `INSERT INTO auth_sessions
       (id, account_id, device_id, refresh_token_hash, token_version, created_at, last_seen_at, expires_at)
       VALUES ('ses_old', 'acc_old', 'dev_old', 'hash', 1, ?, ?, ?)`,
      [now, now, now + 60_000],
    );

    await migrate(databasePool(), 24);

    assert.equal((await get<{ status: string }>(
      "SELECT status FROM accounts WHERE id = 'acc_old'",
    ))?.status, "disabled");
    assert.equal((await get<{ status: string }>(
      "SELECT status FROM accounts WHERE id = 'acc_xu'",
    ))?.status, "active");
    assert.ok((await get<{ revoked_at: number | null }>(
      "SELECT revoked_at FROM auth_sessions WHERE id = 'ses_old'",
    ))?.revoked_at);
    assert.equal((await get<{ name: string | null }>(
      "SELECT to_regclass('public.couple_invites') AS name",
    ))?.name, null);
  }, { migrateThrough: 23 });
});
