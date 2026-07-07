import { all, run, type SharedItemRow } from "../db";
import type { AuthUser } from "../types";

function parse(value: string): unknown {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

export async function getSharedState() {
  const rows = await all<SharedItemRow>("SELECT * FROM shared_items ORDER BY key ASC");
  return Object.fromEntries(
    rows.map((row) => [
      row.key,
      {
        value: parse(row.value_json),
        updatedBy: row.updated_by,
        updatedAt: row.updated_at,
      },
    ]),
  );
}

export async function setSharedItem(user: AuthUser, key: string, value: unknown) {
  const now = Date.now();
  await run(
    `INSERT INTO shared_items (key, value_json, updated_by, updated_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET
       value_json = excluded.value_json,
       updated_by = excluded.updated_by,
       updated_at = excluded.updated_at`,
    [key, JSON.stringify(value), user.username, now],
  );

  return {
    key,
    value,
    updatedBy: user.username,
    updatedAt: now,
  };
}

export async function deleteSharedItem(key: string) {
  await run("DELETE FROM shared_items WHERE key = ?", [key]);
}
