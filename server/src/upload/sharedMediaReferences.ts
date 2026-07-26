import { refreshSignedMediaUrl } from "./mediaAccess";

export type SharedUploadPurpose = "avatar" | "sticker";

export interface SharedMediaUrl {
  url: string;
  purpose: SharedUploadPurpose;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function refreshedUrl(value: unknown): unknown {
  return typeof value === "string" ? refreshSignedMediaUrl(value) ?? value : value;
}

function refreshObjectUrl(value: unknown): unknown {
  if (!isObject(value) || typeof value.url !== "string") return value;
  return { ...value, url: refreshedUrl(value.url) };
}

/**
 * Shared avatar and sticker records persist longer than the media URL TTL. Refresh
 * only their URL fields at API boundaries while leaving unrelated shared JSON intact.
 */
export function refreshSharedMediaReferences(key: string, value: unknown): unknown {
  if (key.startsWith("avatar_")) return refreshObjectUrl(value);
  if (key === "avatars" && isObject(value)) {
    return Object.fromEntries(Object.entries(value).map(([username, url]) => [username, refreshedUrl(url)]));
  }
  if (!key.startsWith("stickers_user_") || !isObject(value)) return value;
  return {
    ...value,
    items: Array.isArray(value.items) ? value.items.map(refreshObjectUrl) : value.items,
    itemTombstones: Array.isArray(value.itemTombstones)
      ? value.itemTombstones.map(refreshObjectUrl)
      : value.itemTombstones,
  };
}

/**
 * Returns live file references only. Sticker tombstones intentionally do not retain
 * the underlying file after the sticker has left both the library and message history.
 */
export function sharedMediaUrls(key: string, value: unknown): SharedMediaUrl[] {
  const references: SharedMediaUrl[] = [];
  const add = (url: unknown, purpose: SharedUploadPurpose) => {
    if (typeof url === "string") references.push({ url, purpose });
  };
  if (key.startsWith("avatar_") && isObject(value)) {
    add(value.url, "avatar");
  } else if (key === "avatars" && isObject(value)) {
    for (const url of Object.values(value)) add(url, "avatar");
  } else if (key.startsWith("stickers_user_") && isObject(value) && Array.isArray(value.items)) {
    for (const item of value.items) {
      if (!isObject(item)) continue;
      add(item.url, "sticker");
    }
  }
  return [...new Map(references.map((reference) => [`${reference.purpose}:${reference.url}`, reference])).values()];
}
