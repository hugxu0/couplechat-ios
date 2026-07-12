import crypto from "node:crypto";
import { all } from "../db";

export interface BarkRecipient {
  username: string;
  barkKey: string;
  endpointKey: string;
}

export async function listBarkRecipients(usernames?: string[]): Promise<BarkRecipient[]> {
  if (usernames?.length === 0) return [];
  const filter = usernames?.length
    ? `AND account.username IN (${usernames.map(() => "?").join(",")})`
    : "";
  const params = usernames ?? [];
  const rows = await all<{ username: string; bark_key: string; endpoint_key: string }>(
    `SELECT account.username, endpoint.secret_value AS bark_key,
            endpoint.endpoint_fingerprint AS endpoint_key
       FROM accounts account
       JOIN devices device ON device.account_id = account.id AND device.revoked_at IS NULL
       JOIN device_push_endpoints endpoint ON endpoint.device_id = device.id
        AND endpoint.provider = 'bark' AND endpoint.enabled = TRUE
      WHERE account.status = 'active' ${filter}
     UNION ALL
     SELECT account.username, account.bark_key, md5(account.bark_key) AS endpoint_key
       FROM accounts account
      WHERE account.status = 'active' AND account.bark_key IS NOT NULL ${filter}
        AND NOT EXISTS (
          SELECT 1 FROM devices device
          JOIN device_push_endpoints endpoint ON endpoint.device_id = device.id
          WHERE device.account_id = account.id AND device.revoked_at IS NULL
            AND endpoint.provider = 'bark' AND endpoint.enabled = TRUE
            AND endpoint.secret_value = account.bark_key
        )`,
    [...params, ...params],
  );
  const seen = new Set<string>();
  return rows.flatMap((row) => {
    const endpointKey = row.endpoint_key || crypto.createHash("md5").update(row.bark_key).digest("hex");
    const key = `${row.username}\u0000${endpointKey}`;
    if (seen.has(key)) return [];
    seen.add(key);
    return [{ username: row.username, barkKey: row.bark_key, endpointKey }];
  });
}

export async function listCoupleBarkRecipients(coupleId: string): Promise<BarkRecipient[]> {
  const members = await all<{ username: string }>(
    `SELECT account.username FROM couple_members member
     JOIN accounts account ON account.id = member.account_id AND account.status = 'active'
     WHERE member.couple_id = ? AND member.state = 'active'
     ORDER BY member.joined_at ASC`,
    [coupleId],
  );
  return listBarkRecipients(members.map((member) => member.username));
}
