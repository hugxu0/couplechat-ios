import { all, get, run, type AccountRow } from "../db";
import { config } from "../config";
import { hashPassword, verifyPassword } from "./password";

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
  if (seed.length === 0 && config.isProduction) {
    throw new Error("COUPLECHAT_ACCOUNTS is required for first production boot");
  }

  const now = Date.now();
  for (const account of seed) {
    const existing = get<AccountRow>("SELECT * FROM accounts WHERE username = ?", [account.username]);
    if (existing) continue;

    run(
      `INSERT INTO accounts (username, display_name, password_hash, avatar, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [account.username, account.displayName, hashPassword(account.password), account.avatar, now, now],
    );
  }
}

export async function listPublicAccounts() {
  const rows = all<Pick<AccountRow, "username" | "display_name" | "avatar">>(
    "SELECT username, display_name, avatar FROM accounts ORDER BY created_at ASC",
  );
  return rows.map((row) => ({
    username: row.username,
    name: row.display_name,
    avatar: row.avatar,
  }));
}

export async function authenticate(username: string, password: string) {
  const account = get<AccountRow>("SELECT * FROM accounts WHERE username = ?", [username]);
  if (!account || !verifyPassword(password, account.password_hash)) return null;
  return {
    username: account.username,
    name: account.display_name,
  };
}

export async function setBarkKey(username: string, barkKey: string | null) {
  run("UPDATE accounts SET bark_key = ?, updated_at = ? WHERE username = ?", [barkKey, Date.now(), username]);
}
