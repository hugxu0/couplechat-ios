import { all, run, type SharedItemRow } from "../db";
import type { AuthUser } from "../types";

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

export async function getSharedState() {
  const rows = await all<SharedItemRow>("SELECT * FROM shared_items ORDER BY key ASC");
  const state = Object.fromEntries(
    rows.map((row) => [
      row.key,
      {
        value: parse(row.value_json),
        updatedBy: row.updated_by,
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
