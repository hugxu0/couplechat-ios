import { nanoid } from "nanoid";
import { all, get, transaction, type DatabaseTransaction } from "../db";
import { activeIdentity, activeIdentityIn } from "../auth/identity";
import type { AuthUser } from "../types";
import { appendSyncEvent } from "../sync/events";

interface AlbumRow {
  id: string;
  title: string;
  summary: string;
  cover_asset_id: string | null;
  created_at: number;
  updated_at: number;
  version: number;
  item_count?: number;
  cover_url?: string | null;
}

interface AssetRow {
  id: string;
  source_message_id: string;
  kind: string;
  mime_type: string;
  url: string;
  size: number;
  taken_at: number;
  created_at: number;
  version: number;
  note_id?: string | null;
  note_text?: string | null;
  note_version?: number | null;
}

interface ItemRow extends AssetRow {
  item_id: string;
  added_at: number;
  sort_order: number;
}

function mapAlbum(row: AlbumRow) {
  return {
    id: row.id,
    title: row.title,
    summary: row.summary,
    coverAssetId: row.cover_asset_id ?? undefined,
    coverURL: row.cover_url ?? undefined,
    itemCount: Number(row.item_count ?? 0),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    version: row.version,
  };
}

function mapAsset(row: AssetRow) {
  return {
    id: row.id,
    sourceMessageId: row.source_message_id,
    kind: row.kind,
    mimeType: row.mime_type,
    url: row.url,
    size: row.size,
    takenAt: row.taken_at,
    createdAt: row.created_at,
    version: row.version,
    note: row.note_id ? {
      id: row.note_id,
      text: row.note_text ?? "",
      version: row.note_version ?? 0,
    } : undefined,
  };
}

function encodeCursor(value: unknown): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function decodeCursor(cursor?: string): [number, string] | null {
  if (!cursor) return null;
  try {
    const value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    return Array.isArray(value) && typeof value[0] === "number" && typeof value[1] === "string"
      ? [value[0], value[1]] : null;
  } catch {
    return null;
  }
}

async function ownedAlbum(db: Pick<DatabaseTransaction, "get">, coupleId: string, albumId: string, lock = false) {
  return db.get<AlbumRow>(
    `SELECT album.*, cover.url AS cover_url,
            (SELECT COUNT(*) FROM album_items item WHERE item.album_id = album.id) AS item_count
       FROM albums album LEFT JOIN media_assets cover ON cover.id = album.cover_asset_id
      WHERE album.id = ? AND album.couple_id = ?${lock ? " FOR UPDATE OF album" : ""}`,
    [albumId, coupleId],
  );
}

export async function listAlbums(user: AuthUser, cursor?: string, limit = 30) {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const decoded = decodeCursor(cursor);
  const rows = await all<AlbumRow>(
    `SELECT album.*, cover.url AS cover_url,
            (SELECT COUNT(*) FROM album_items item WHERE item.album_id = album.id) AS item_count
       FROM albums album LEFT JOIN media_assets cover ON cover.id = album.cover_asset_id
      WHERE album.couple_id = ?
        AND (?::BIGINT IS NULL OR (album.updated_at, album.id) < (?, ?))
      ORDER BY album.updated_at DESC, album.id DESC LIMIT ?`,
    [identity.coupleId, decoded?.[0] ?? null, decoded?.[0] ?? 0, decoded?.[1] ?? "", limit + 1],
  );
  const page = rows.slice(0, limit);
  return {
    albums: page.map(mapAlbum),
    nextCursor: rows.length > limit && page.length
      ? encodeCursor([page.at(-1)!.updated_at, page.at(-1)!.id]) : undefined,
    hasMore: rows.length > limit,
  };
}

export async function createAlbum(user: AuthUser, input: { title: string; summary: string }) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) return null;
    const now = Date.now();
    const row: AlbumRow = {
      id: `alb_${nanoid(16)}`,
      title: input.title,
      summary: input.summary,
      cover_asset_id: null,
      created_at: now,
      updated_at: now,
      version: 0,
      item_count: 0,
    };
    await db.run(
      `INSERT INTO albums
       (id, couple_id, title, summary, created_by_account_id, created_at, updated_at, version)
       VALUES (?, ?, ?, ?, ?, ?, ?, 0)`,
      [row.id, identity.coupleId, row.title, row.summary, identity.accountId, now, now],
    );
    await appendSyncEvent(db, {
      coupleId: identity.coupleId,
      entityType: "album",
      entityId: row.id,
      operation: "upsert",
      payload: mapAlbum(row),
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return mapAlbum(row);
  });
}

export async function updateAlbum(
  user: AuthUser,
  albumId: string,
  input: { title?: string; summary?: string; coverAssetId?: string | null; baseVersion: number },
) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) return null;
    const album = await ownedAlbum(db, identity.coupleId, albumId, true);
    if (!album) return null;
    if (album.version !== input.baseVersion) return { conflict: true as const, album: mapAlbum(album) };
    if (input.coverAssetId) {
      const item = await db.get(
        `SELECT 1 AS found FROM album_items item JOIN media_assets asset ON asset.id = item.asset_id
         WHERE item.album_id = ? AND asset.id = ? AND asset.couple_id = ?`,
        [albumId, input.coverAssetId, identity.coupleId],
      );
      if (!item) return { invalidCover: true as const };
    }
    const title = input.title ?? album.title;
    const summary = input.summary ?? album.summary;
    const cover = input.coverAssetId === undefined ? album.cover_asset_id : input.coverAssetId;
    const now = Date.now();
    await db.run(
      `UPDATE albums SET title = ?, summary = ?, cover_asset_id = ?, updated_at = ?,
       version = version + 1 WHERE id = ?`,
      [title, summary, cover, now, albumId],
    );
    const updated = await ownedAlbum(db, identity.coupleId, albumId);
    if (!updated) return null;
    await appendSyncEvent(db, {
      coupleId: identity.coupleId,
      entityType: "album",
      entityId: albumId,
      operation: "upsert",
      payload: mapAlbum(updated),
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return { conflict: false as const, invalidCover: false as const, album: mapAlbum(updated) };
  });
}

export async function deleteAlbum(user: AuthUser, albumId: string, baseVersion: number) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) return null;
    const album = await ownedAlbum(db, identity.coupleId, albumId, true);
    if (!album) return null;
    if (album.version !== baseVersion) return { conflict: true as const, album: mapAlbum(album) };
    const now = Date.now();
    await db.run("DELETE FROM albums WHERE id = ?", [albumId]);
    await appendSyncEvent(db, {
      coupleId: identity.coupleId,
      entityType: "album",
      entityId: albumId,
      operation: "delete",
      payload: { id: albumId },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return { conflict: false as const };
  });
}

export async function listAlbumItems(user: AuthUser, albumId: string, cursor: string | undefined, limit: number) {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const album = await get<AlbumRow>(
    `SELECT album.*, cover.url AS cover_url,
            (SELECT COUNT(*) FROM album_items item WHERE item.album_id = album.id) AS item_count
     FROM albums album LEFT JOIN media_assets cover ON cover.id = album.cover_asset_id
     WHERE album.id = ? AND album.couple_id = ?`,
    [albumId, identity.coupleId],
  );
  if (!album) return null;
  const decoded = decodeCursor(cursor);
  const rows = await all<ItemRow>(
    `SELECT item.id AS item_id, item.added_at, item.sort_order, asset.*,
            note.id AS note_id, note.text AS note_text, note.version AS note_version
       FROM album_items item
       JOIN media_assets asset ON asset.id = item.asset_id
       LEFT JOIN media_notes note ON note.asset_id = asset.id
      WHERE item.album_id = ?
        AND (?::BIGINT IS NULL OR (item.sort_order, item.id) < (?, ?))
      ORDER BY item.sort_order DESC, item.id DESC LIMIT ?`,
    [albumId, decoded?.[0] ?? null, decoded?.[0] ?? 0, decoded?.[1] ?? "", limit + 1],
  );
  const page = rows.slice(0, limit);
  return {
    album: mapAlbum(album),
    items: page.map((row) => ({ id: row.item_id, addedAt: row.added_at, asset: mapAsset(row) })),
    nextCursor: rows.length > limit && page.length
      ? encodeCursor([page.at(-1)!.sort_order, page.at(-1)!.item_id]) : undefined,
    hasMore: rows.length > limit,
  };
}

function mediaKind(mimeType: string): string | null {
  if (mimeType.startsWith("image/")) return "image";
  if (mimeType.startsWith("video/")) return "video";
  return null;
}

export async function addMessageMedia(user: AuthUser, albumId: string, messageId: string) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) return null;
    const album = await ownedAlbum(db, identity.coupleId, albumId, true);
    if (!album) return null;
    const message = await db.get<{ id: string; ts: number }>(
      `SELECT message.id, message.ts FROM messages message
       JOIN conversations conversation ON conversation.id = message.conversation_id
       WHERE message.id = ? AND conversation.couple_id = ?`,
      [messageId, identity.coupleId],
    );
    if (!message) return { messageMissing: true as const };
    const uploads = await db.all<{
      id: string; mime_type: string; url: string; size: number;
    }>(
      `SELECT upload.id, upload.mime_type, upload.url, upload.size
       FROM uploads upload WHERE upload.message_id = ? ORDER BY upload.created_at, upload.id FOR UPDATE`,
      [messageId],
    );
    const supported = uploads.filter((upload) => mediaKind(upload.mime_type));
    if (!supported.length) return { noMedia: true as const };
    const now = Date.now();
    const added: Array<{ itemId: string; asset: ReturnType<typeof mapAsset> }> = [];
    for (const [index, upload] of supported.entries()) {
      let asset = await db.get<AssetRow>(
        "SELECT * FROM media_assets WHERE couple_id = ? AND source_upload_id = ?",
        [identity.coupleId, upload.id],
      );
      if (!asset) {
        const assetId = `med_${nanoid(16)}`;
        await db.run(
          `INSERT INTO media_assets
           (id, couple_id, source_upload_id, source_message_id, created_by_account_id,
            kind, mime_type, url, size, taken_at, created_at, version)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
           ON CONFLICT(couple_id, source_upload_id) DO NOTHING`,
          [assetId, identity.coupleId, upload.id, messageId, identity.accountId,
            mediaKind(upload.mime_type), upload.mime_type, upload.url, upload.size, message.ts, now],
        );
        asset = await db.get<AssetRow>(
          "SELECT * FROM media_assets WHERE couple_id = ? AND source_upload_id = ?",
          [identity.coupleId, upload.id],
        );
      }
      if (!asset) continue;
      const itemId = `albi_${nanoid(16)}`;
      const inserted = await db.run(
        `INSERT INTO album_items (id, album_id, asset_id, added_by_account_id, added_at, sort_order)
         VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(album_id, asset_id) DO NOTHING`,
        [itemId, albumId, asset.id, identity.accountId, now, now * 100 + index],
      );
      if (inserted) added.push({ itemId, asset: mapAsset(asset) });
    }
    if (added.length) {
      const cover = album.cover_asset_id ?? added[0].asset.id;
      await db.run(
        "UPDATE albums SET cover_asset_id = ?, updated_at = ?, version = version + 1 WHERE id = ?",
        [cover, now, albumId],
      );
      const updated = await ownedAlbum(db, identity.coupleId, albumId);
      await appendSyncEvent(db, {
        coupleId: identity.coupleId,
        entityType: "album",
        entityId: albumId,
        operation: "upsert",
        payload: { album: updated ? mapAlbum(updated) : undefined, added },
        actorAccountId: identity.accountId,
        actorDeviceId: user.deviceId,
        createdAt: now,
      });
    }
    return { messageMissing: false as const, noMedia: false as const, added };
  });
}

export async function removeAlbumItem(user: AuthUser, albumId: string, itemId: string) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) return null;
    const item = await db.get<{ id: string; asset_id: string }>(
      `SELECT item.id, item.asset_id FROM album_items item
       JOIN albums album ON album.id = item.album_id
       WHERE item.id = ? AND item.album_id = ? AND album.couple_id = ? FOR UPDATE OF item`,
      [itemId, albumId, identity.coupleId],
    );
    if (!item) return null;
    const now = Date.now();
    await db.run("DELETE FROM album_items WHERE id = ?", [itemId]);
    await db.run(
      `UPDATE albums SET cover_asset_id = CASE WHEN cover_asset_id = ? THEN NULL ELSE cover_asset_id END,
       updated_at = ?, version = version + 1 WHERE id = ?`,
      [item.asset_id, now, albumId],
    );
    await appendSyncEvent(db, {
      coupleId: identity.coupleId,
      entityType: "album_item",
      entityId: itemId,
      operation: "delete",
      payload: { id: itemId, albumId, assetId: item.asset_id },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return { ok: true };
  });
}

export async function upsertMediaNote(
  user: AuthUser,
  assetId: string,
  text: string,
  baseVersion?: number,
) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) return null;
    const asset = await db.get<AssetRow>(
      "SELECT * FROM media_assets WHERE id = ? AND couple_id = ? FOR UPDATE",
      [assetId, identity.coupleId],
    );
    if (!asset) return null;
    const note = await db.get<{ id: string; version: number }>(
      "SELECT id, version FROM media_notes WHERE asset_id = ? FOR UPDATE",
      [assetId],
    );
    if (note && baseVersion !== undefined && note.version !== baseVersion) {
      return { conflict: true as const, version: note.version };
    }
    const now = Date.now();
    const noteId = note?.id ?? `note_${nanoid(16)}`;
    await db.run(
      `INSERT INTO media_notes
       (id, asset_id, couple_id, text, updated_by_account_id, created_at, updated_at, version)
       VALUES (?, ?, ?, ?, ?, ?, ?, 0)
       ON CONFLICT(asset_id) DO UPDATE SET text = excluded.text,
         updated_by_account_id = excluded.updated_by_account_id, updated_at = excluded.updated_at,
         version = media_notes.version + 1`,
      [noteId, assetId, identity.coupleId, text, identity.accountId, now, now],
    );
    const updated = await db.get<{ id: string; text: string; version: number }>(
      "SELECT id, text, version FROM media_notes WHERE asset_id = ?",
      [assetId],
    );
    await appendSyncEvent(db, {
      coupleId: identity.coupleId,
      entityType: "media_note",
      entityId: noteId,
      operation: "upsert",
      payload: { assetId, note: updated },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return { conflict: false as const, note: updated };
  });
}

export async function deleteMediaAsset(user: AuthUser, assetId: string) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) return null;
    const asset = await db.get<{ id: string }>(
      "SELECT id FROM media_assets WHERE id = ? AND couple_id = ? FOR UPDATE",
      [assetId, identity.coupleId],
    );
    if (!asset) return null;
    const now = Date.now();
    await db.run("DELETE FROM media_assets WHERE id = ?", [assetId]);
    await appendSyncEvent(db, {
      coupleId: identity.coupleId,
      entityType: "media_asset",
      entityId: assetId,
      operation: "delete",
      payload: { id: assetId },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return { ok: true };
  });
}

export async function onThisDay(
  user: AuthUser,
  input: { timezone: string; date: string; cursor?: string; limit: number },
) {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const [year, month, day] = input.date.split("-").map(Number);
  const includeLeapDay = month === 2 && day === 28 && !isLeapYear(year);
  const decoded = decodeCursor(input.cursor);
  const rows = await all<AssetRow>(
    `SELECT asset.*, note.id AS note_id, note.text AS note_text, note.version AS note_version
       FROM media_assets asset
       LEFT JOIN media_notes note ON note.asset_id = asset.id
      WHERE asset.couple_id = ?
        AND EXTRACT(YEAR FROM to_timestamp(asset.taken_at / 1000.0) AT TIME ZONE ?) < ?
        AND EXTRACT(MONTH FROM to_timestamp(asset.taken_at / 1000.0) AT TIME ZONE ?) = ?
        AND EXTRACT(DAY FROM to_timestamp(asset.taken_at / 1000.0) AT TIME ZONE ?)
            ${includeLeapDay ? "IN (28, 29)" : "= ?"}
        AND (?::BIGINT IS NULL OR (asset.taken_at, asset.id) < (?, ?))
      ORDER BY asset.taken_at DESC, asset.id DESC LIMIT ?`,
    includeLeapDay
      ? [identity.coupleId, input.timezone, year, input.timezone, month, input.timezone,
          decoded?.[0] ?? null, decoded?.[0] ?? 0, decoded?.[1] ?? "", input.limit + 1]
      : [identity.coupleId, input.timezone, year, input.timezone, month, input.timezone, day,
          decoded?.[0] ?? null, decoded?.[0] ?? 0, decoded?.[1] ?? "", input.limit + 1],
  );
  const page = rows.slice(0, input.limit);
  return {
    date: input.date,
    timezone: input.timezone,
    assets: page.map(mapAsset),
    nextCursor: rows.length > input.limit && page.length
      ? encodeCursor([page.at(-1)!.taken_at, page.at(-1)!.id]) : undefined,
    hasMore: rows.length > input.limit,
  };
}

function isLeapYear(year: number): boolean {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}
