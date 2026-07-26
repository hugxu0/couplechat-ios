import { all, transaction, type DatabaseTransaction, type UploadRow } from "../db";
import type { AuthUser } from "../types";
import { activeIdentity, activeIdentityIn } from "../auth/identity";
import { appendSyncEvent } from "../sync/events";
import { errorCodes } from "../errors/errorCodes";
import {
  refreshSharedMediaReferences,
  sharedMediaUrls,
  type SharedMediaUrl,
} from "../upload/sharedMediaReferences";
import { legacyUploadFilenameFromUrl, mediaUploadIdFromUrl } from "../upload/mediaAccess";

interface CoupleSettingRow {
  key: string;
  value_json: string;
  updated_by_username: string;
  updated_at: number;
}

function parse(value: string): unknown {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

export async function getSharedState(user: AuthUser) {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return {};
  const rows = await all<CoupleSettingRow>(
    "SELECT * FROM couple_settings WHERE couple_id = ? ORDER BY key ASC",
    [identity.coupleId],
  );
  const state = Object.fromEntries(
    rows.map((row) => [
      row.key,
      {
        value: refreshSharedMediaReferences(row.key, parse(row.value_json)),
        updatedBy: row.updated_by_username,
        updatedAt: row.updated_at,
      },
    ]),
  ) as Record<string, { value: unknown; updatedBy: string; updatedAt: number }>;

  // 将旧网页端的聚合键在 API 边界归一化为原生客户端模型；数据库原值保留，便于审计。
  const avatars = state.avatars?.value;
  if (avatars && typeof avatars === "object" && !Array.isArray(avatars)) {
    for (const [username, url] of Object.entries(avatars as Record<string, unknown>)) {
      if (typeof url === "string" && !state[`avatar_${username}`]) {
        state[`avatar_${username}`] = { ...state.avatars, value: { url } };
      }
    }
  }

  const statuses = state.statuses?.value;
  if (!state.chat_statuses && statuses && typeof statuses === "object" && !Array.isArray(statuses)) {
    const normalized = Object.fromEntries(
      Object.entries(statuses as Record<string, unknown>).flatMap(([username, value]) => {
        if (typeof value === "string") return [[username, value]];
        if (value && typeof value === "object" && typeof (value as Record<string, unknown>).text === "string") {
          return [[username, (value as Record<string, unknown>).text as string]];
        }
        return [];
      }),
    );
    state.chat_statuses = { ...state.statuses, value: normalized };
  }

  const legacyAnniversaries = Array.isArray(state.anniversaries?.value)
    ? state.anniversaries.value as Array<Record<string, unknown>>
    : null;
  if (legacyAnniversaries) {
    const items = legacyAnniversaries.flatMap((item, index) => {
      const title = typeof item.title === "string" ? item.title : typeof item.name === "string" ? item.name : null;
      const date = typeof item.date === "string" ? item.date : null;
      if (!title || !date) return [];
      return [{
        id: typeof item.id === "string" ? item.id : `legacy-${index}`,
        title,
        date,
        direction: item.direction === "down" || item.mode === "countdown" ? "down" : "up",
        icon: typeof item.icon === "string" ? item.icon : "heart",
      }];
    });
    state.anniversaries = { ...state.anniversaries, value: { items } };

    if (!state.dates) {
      const lastMeet = items.find((item) => item.title.includes("见面"))?.date;
      const lastFight = items.find((item) => item.title.includes("吵架"))?.date;
      state.dates = {
        ...state.anniversaries,
        value: {
          together: typeof state.loveDate?.value === "string" ? state.loveDate.value : undefined,
          lastMeet,
          lastFight,
        },
      };
    }
  }

  // 历史网页端允许写入顶层字符串、数组或 null；原生客户端共享状态只接受对象。
  // 可识别的 loveDate 升级到 dates，其余异常键不下发，以免单条旧记录阻断登录。
  const loveDate = typeof state.loveDate?.value === "string" ? state.loveDate.value : undefined;
  if (!isJsonObject(state.dates?.value) && loveDate) {
    state.dates = { ...state.loveDate, value: { together: loveDate } };
  }
  for (const [key, entry] of Object.entries(state)) {
    if (!isJsonObject(entry.value)) delete state[key];
  }

  return state;
}

async function lockSharedMediaUploads(
  db: DatabaseTransaction,
  user: AuthUser,
  coupleId: string,
  key: string,
  value: unknown,
): Promise<void> {
  const scopeSql = "(upload.owner = ? OR owner_member.couple_id = ?)";
  const scopeParams = [user.username, coupleId];
  const resolved = new Map<string, { id: string; references: Array<{ reference: SharedMediaUrl; legacy: boolean }> }>();

  // Resolve first without taking row locks, then acquire every lock in upload-id
  // order. This makes concurrent shared:set transactions use one global order
  // even when their JSON arrays arrive in opposite orders.
  for (const reference of sharedMediaUrls(key, value)) {
    const uploadId = mediaUploadIdFromUrl(reference.url);
    const legacyFilename = uploadId ? undefined : legacyUploadFilenameFromUrl(reference.url);
    if (!uploadId && !legacyFilename) throw new Error(errorCodes.uploadNotFound);
    const legacySuffix = legacyFilename ? `/uploads/${legacyFilename}` : undefined;
    const upload = uploadId
      ? await db.get<Pick<UploadRow, "id" | "purpose" | "mime_type">>(
          `SELECT upload.id, upload.purpose, upload.mime_type
             FROM uploads upload
             LEFT JOIN accounts owner_account ON owner_account.username = upload.owner
             LEFT JOIN couple_members owner_member
               ON owner_member.account_id = owner_account.id AND owner_member.state = 'active'
            WHERE upload.id = ? AND ${scopeSql}`,
          [uploadId, ...scopeParams],
        )
      : await db.get<Pick<UploadRow, "id" | "purpose" | "mime_type">>(
          `SELECT upload.id, upload.purpose, upload.mime_type
             FROM uploads upload
             LEFT JOIN accounts owner_account ON owner_account.username = upload.owner
             LEFT JOIN couple_members owner_member
               ON owner_member.account_id = owner_account.id AND owner_member.state = 'active'
            WHERE (upload.url = ? OR RIGHT(upload.url, LENGTH(?)) = ?)
              AND ${scopeSql}
            ORDER BY upload.created_at DESC, upload.id COLLATE "C" DESC
            LIMIT 1`,
          [reference.url, legacySuffix, legacySuffix, ...scopeParams],
        );
    if (!upload) throw new Error(errorCodes.uploadNotFound);
    const entry = resolved.get(upload.id) ?? { id: upload.id, references: [] };
    entry.references.push({ reference, legacy: Boolean(legacyFilename) });
    resolved.set(upload.id, entry);
  }

  for (const entry of [...resolved.values()].sort((left, right) =>
    left.id < right.id ? -1 : left.id > right.id ? 1 : 0
  )) {
    const upload = await db.get<Pick<UploadRow, "id" | "purpose" | "mime_type">>(
      `SELECT upload.id, upload.purpose, upload.mime_type
         FROM uploads upload
         LEFT JOIN accounts owner_account ON owner_account.username = upload.owner
         LEFT JOIN couple_members owner_member
           ON owner_member.account_id = owner_account.id AND owner_member.state = 'active'
        WHERE upload.id = ? AND ${scopeSql}
        FOR UPDATE OF upload`,
      [entry.id, ...scopeParams],
    );
    if (!upload) throw new Error(errorCodes.uploadNotFound);
    for (const { reference, legacy } of entry.references) {
      const validPurpose = upload.purpose === reference.purpose ||
        (legacy && upload.purpose === "legacy");
      if (!validPurpose || !upload.mime_type.startsWith("image/")) {
        throw new Error(errorCodes.uploadPurposeMismatch);
      }
    }
  }
}

export async function setSharedItem(user: AuthUser, key: string, value: unknown) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) throw new Error("couple_required");
    const normalizedValue = refreshSharedMediaReferences(key, value);
    // Reference writers and the garbage collector lock the same upload row. A
    // cleanup can therefore never commit between validating and persisting a URL.
    await lockSharedMediaUploads(db, user, identity.coupleId, key, normalizedValue);
    const now = Date.now();
    await db.run(
      `INSERT INTO couple_settings
       (couple_id, key, value_json, updated_by_account_id, updated_by_username, updated_at, version)
       VALUES (?, ?, ?, ?, ?, ?, 0)
       ON CONFLICT(couple_id, key) DO UPDATE SET
         value_json = excluded.value_json,
         updated_by_account_id = excluded.updated_by_account_id,
         updated_by_username = excluded.updated_by_username,
         updated_at = excluded.updated_at`,
      [identity.coupleId, key, JSON.stringify(normalizedValue), identity.accountId, user.username, now],
    );
    const update = { key, value: normalizedValue, updatedBy: user.username, updatedAt: now };
    const version = await appendSyncEvent(db, {
      coupleId: identity.coupleId,
      entityType: "coupleSetting",
      entityId: key,
      operation: "upsert",
      payload: update,
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    await db.run(
      "UPDATE couple_settings SET version = ? WHERE couple_id = ? AND key = ?",
      [version, identity.coupleId, key],
    );
    return update;
  });
}
