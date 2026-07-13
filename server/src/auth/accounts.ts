import { all, get, run, type AccountRow } from "../db";
import { config } from "../config";
import { hashPassword, verifyPassword } from "./password";
import type { AuthUser } from "../types";

interface SeedAccount {
  username: string;
  displayName: string;
  password: string;
  avatar: string;
}

function parseSeedAccounts(): SeedAccount[] {
  return config.accountsSeed
    .split(";")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const [username, displayName, password, avatar = ""] = entry.split("|");
      if (!username || !displayName || !password) {
        throw new Error("Invalid COUPLECHAT_ACCOUNTS entry. Expected username|displayName|password|avatar");
      }
      return { username, displayName, password, avatar };
    });
}

export async function seedAccounts() {
  const seed = parseSeedAccounts();
  const fixedSeed = seed.filter((item) => item.username === "xu" || item.username === "si");
  const fixedUsernames = new Set(fixedSeed.map((item) => item.username));
  if ((fixedSeed.length !== 2 || fixedUsernames.size !== 2) && config.isProduction) {
    throw new Error("COUPLECHAT_ACCOUNTS must define exactly the fixed xu and si accounts");
  }

  const now = Date.now();
  for (const account of fixedSeed) {
    const existing = await get<AccountRow>("SELECT * FROM accounts WHERE username = ?", [account.username]);
    if (existing) continue;

    await run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, 'active', 0, ?, ?)`,
      [legacyAccountId(account.username), account.username, account.displayName,
        hashPassword(account.password), account.avatar, now, now],
    );
  }
  await ensureLegacyCouple();
  await ensureLegacyConversations();
}

export function legacyAccountId(username: string): string {
  return `acc_legacy_${username}`;
}

export async function ensureLegacyCouple(): Promise<void> {
  const xu = await get<AccountRow & { id: string }>("SELECT * FROM accounts WHERE username = 'xu'");
  const si = await get<AccountRow & { id: string }>("SELECT * FROM accounts WHERE username = 'si'");
  if (!xu || !si) return;
  const createdAt = Math.min(xu.created_at, si.created_at);
  const updatedAt = Math.max(xu.updated_at, si.updated_at);
  await run(
    `INSERT INTO couples (id, name, status, created_by_account_id, created_at, updated_at, version)
     VALUES ('cpl_legacy_xusi', '小旭和小偲', 'active', ?, ?, ?, 0)
     ON CONFLICT(id) DO NOTHING`,
    [xu.id, createdAt, updatedAt],
  );
  await run(
    `INSERT INTO couple_members (id, couple_id, account_id, role, state, joined_at, updated_at)
     VALUES ('mem_legacy_xu', 'cpl_legacy_xusi', ?, 'owner', 'active', ?, ?)
     ON CONFLICT(id) DO NOTHING`,
    [xu.id, xu.created_at, xu.updated_at],
  );
  await run(
    `INSERT INTO couple_members (id, couple_id, account_id, role, state, joined_at, updated_at)
     VALUES ('mem_legacy_si', 'cpl_legacy_xusi', ?, 'member', 'active', ?, ?)
     ON CONFLICT(id) DO NOTHING`,
    [si.id, si.created_at, si.updated_at],
  );
}

export async function ensureLegacyConversations(): Promise<void> {
  const now = Date.now();
  if (await get("SELECT 1 AS found FROM couples WHERE id = 'cpl_legacy_xusi'")) {
    await run(
      `INSERT INTO conversations (id, kind, couple_id, created_at)
       VALUES ('conv_legacy_couple', 'couple', 'cpl_legacy_xusi', ?)
       ON CONFLICT(id) DO NOTHING`,
      [now],
    );
  }
  for (const username of ["xu", "si"]) {
    const account = await get<AccountRow>("SELECT * FROM accounts WHERE username = ?", [username]);
    if (!account) continue;
    await run(
      `INSERT INTO conversations (id, kind, owner_account_id, created_at)
       VALUES (?, 'ai', ?, ?)
       ON CONFLICT(id) DO NOTHING`,
      [`conv_legacy_ai_${username}`, account.id, account.created_at],
    );
  }
}

export async function listPublicAccounts(user?: AuthUser) {
  const rows = user
    ? await all<Pick<AccountRow, "username" | "display_name" | "avatar">>(
        `SELECT account.username, account.display_name, account.avatar
           FROM accounts viewer
           JOIN couple_members own_member ON own_member.account_id = viewer.id AND own_member.state = 'active'
           JOIN couple_members member ON member.couple_id = own_member.couple_id AND member.state = 'active'
           JOIN accounts account ON account.id = member.account_id AND account.status = 'active'
          WHERE viewer.username = ? ORDER BY member.joined_at ASC`,
        [user.username],
      )
    : await all<Pick<AccountRow, "username" | "display_name" | "avatar">>(
        "SELECT username, display_name, avatar FROM accounts WHERE username IN ('xu','si') ORDER BY created_at ASC",
      );
  return rows.map((row) => ({
    username: row.username,
    name: row.display_name,
    avatar: row.avatar,
  }));
}

export async function authenticate(username: string, password: string) {
  const account = await get<AccountRow & { couple_id: string | null; member_id: string | null }>(
    `SELECT account.*, member.couple_id, member.id AS member_id
       FROM accounts account
       LEFT JOIN couple_members member ON member.account_id = account.id AND member.state = 'active'
      WHERE account.username = ?
        AND account.username IN ('xu', 'si')
        AND account.status = 'active'`,
    [username],
  );
  if (!account || !verifyPassword(password, account.password_hash)) return null;
  return {
    username: account.username,
    name: account.display_name,
    accountId: account.id,
    coupleId: account.couple_id ?? undefined,
    memberId: account.member_id ?? undefined,
  };
}

export async function setBarkKey(username: string, barkKey: string | null) {
  await run("UPDATE accounts SET bark_key = ?, updated_at = ? WHERE username = ?", [barkKey, Date.now(), username]);
}
