import fs from "node:fs/promises";
import path from "node:path";
import { nanoid } from "nanoid";
import { all, run, transaction } from "../db";
import { config } from "../config";
import { removeUploadArtifacts } from "./thumbnail";
import { sharedMediaUrls } from "./sharedMediaReferences";

const ABANDONED_AFTER_MS = 24 * 60 * 60 * 1000;
const UPLOADING_STALE_MS = 2 * 60 * 60 * 1000;
const CLEANUP_INTERVAL_MS = 6 * 60 * 60 * 1000;
const BATCH_SIZE = 500;

interface FileCleanupRow {
  id: string;
  path: string;
  attempt_count: number;
}

interface SharedReferenceRow {
  key: string;
  value_json: string;
}

function isPathInsideUploadDir(candidate: string): boolean {
  const resolved = path.resolve(candidate);
  const root = path.resolve(config.uploadDir);
  return resolved.startsWith(root + path.sep);
}

/**
 * 数据库迁移/业务事务只负责把需要物理删除的路径写入可靠队列；这里在进程
 * 启动和定时任务中幂等落地。文件不存在也视为成功，避免崩溃重启后卡死。
 */
export async function drainFileCleanupQueue(): Promise<number> {
  const rows = await all<FileCleanupRow>(
    `SELECT id, path, attempt_count FROM file_cleanup_queue
      WHERE completed_at IS NULL ORDER BY created_at ASC LIMIT ?`,
    [BATCH_SIZE],
  );
  let completed = 0;
  for (const row of rows) {
    try {
      if (!isPathInsideUploadDir(row.path)) {
        await run(
          `UPDATE file_cleanup_queue SET attempt_count = attempt_count + 1, last_error = ?
           WHERE id = ? AND completed_at IS NULL`,
          ["path_outside_upload_dir", row.id],
        );
        console.warn(`[upload] 拒绝清理越界路径 id=${row.id}`);
        continue;
      }
      await removeUploadArtifacts(row.path);
      completed += await run(
        `UPDATE file_cleanup_queue SET completed_at = ?, attempt_count = attempt_count + 1,
         last_error = NULL WHERE id = ? AND completed_at IS NULL`,
        [Date.now(), row.id],
      );
    } catch (error) {
      await run(
        `UPDATE file_cleanup_queue SET attempt_count = attempt_count + 1, last_error = ?
         WHERE id = ? AND completed_at IS NULL`,
        [error instanceof Error ? error.message.slice(0, 1_000) : String(error).slice(0, 1_000), row.id],
      );
    }
  }
  if (completed > 0) console.info(`[upload] 已完成 ${completed} 个持久文件清理任务`);
  return completed;
}

export async function cleanupAbandonedMessageUploads(now = Date.now()): Promise<number> {
  const queued = await transaction(async (db) => {
    const rows = await db.all<{ id: string; path: string }>(
      `WITH candidates AS (
         SELECT upload.id
           FROM uploads upload
          WHERE upload.purpose IN ('message', 'album') AND upload.message_id IS NULL
            AND upload.created_at < ?
            AND NOT EXISTS (
              SELECT 1 FROM media_assets asset WHERE asset.source_upload_id = upload.id
            )
          ORDER BY upload.id COLLATE "C" ASC
          LIMIT ?
          FOR UPDATE SKIP LOCKED
       )
       DELETE FROM uploads upload
        USING candidates
        WHERE upload.id = candidates.id
          AND upload.purpose IN ('message', 'album') AND upload.message_id IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM media_assets asset WHERE asset.source_upload_id = upload.id
          )
       RETURNING upload.id, upload.path`,
      [now - ABANDONED_AFTER_MS, BATCH_SIZE],
    );
    for (const row of rows) {
      const stillReferenced = await db.get<{ exists: boolean }>(
        "SELECT EXISTS (SELECT 1 FROM uploads WHERE path = ?) AS exists",
        [row.path],
      );
      if (!stillReferenced?.exists) {
        await db.run(
          `INSERT INTO file_cleanup_queue (id, path, reason, created_at)
           VALUES (?, ?, 'abandoned_upload', ?)`,
          [`cleanup_${nanoid(16)}`, row.path, now],
        );
      }
    }
    return rows.length;
  });
  if (queued > 0) console.info(`[upload] 已将 ${queued} 个未绑定附件加入持久清理队列`);
  return queued;
}

function parseSharedValue(value: string): unknown {
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return null;
  }
}

function durableMediaIdentity(url: string): string {
  // These values already exist in the database and may predate the current
  // public origin. Parse only to retain files conservatively; request-time
  // authorization uses the strict same-origin helpers in mediaAccess.ts.
  try {
    const pathname = new URL(url, config.publicBaseURL).pathname;
    const uploadId = /^\/media\/(up_[A-Za-z0-9_-]{8,})(?:\/thumbnail)?\/?$/.exec(pathname)?.[1];
    if (uploadId) return `upload:${uploadId}`;
    const legacyFilename = /^\/uploads\/((?:up_[A-Za-z0-9_-]{8,}|[0-9]{13}-[a-f0-9]{12})\.[a-z0-9]{1,8})$/i
      .exec(pathname)?.[1];
    if (legacyFilename) return `legacy:${legacyFilename}`;
  } catch {
    // Fall through to exact URL identity for malformed historical data.
  }
  return `url:${url}`;
}

/**
 * Reclaims superseded avatars and stickers that are no longer present in shared
 * state or sticker message history. Reference writers lock the same upload rows,
 * so SKIP LOCKED makes creation/replacement race-safe instead of relying on age.
 */
export async function cleanupUnreferencedSharedUploads(now = Date.now()): Promise<number> {
  const queued = await transaction(async (db) => {
    const candidates = await db.all<{ id: string; path: string; url: string }>(
      `SELECT id, path, url
         FROM uploads
        WHERE purpose IN ('avatar', 'sticker') AND message_id IS NULL
          AND created_at < ?
        ORDER BY id COLLATE "C" ASC
        LIMIT ?
        FOR UPDATE SKIP LOCKED`,
      [now - ABANDONED_AFTER_MS, BATCH_SIZE],
    );
    if (candidates.length === 0) return 0;

    const referencedMedia = new Set<string>();
    const settings = await db.all<SharedReferenceRow>(
      `SELECT key, value_json
         FROM couple_settings
        WHERE key = 'avatars' OR LEFT(key, 7) = 'avatar_'
          OR LEFT(key, 14) = 'stickers_user_'`,
    );
    for (const setting of settings) {
      for (const reference of sharedMediaUrls(setting.key, parseSharedValue(setting.value_json))) {
        referencedMedia.add(durableMediaIdentity(reference.url));
      }
    }

    const durableUrls = await db.all<{ url: string }>(
      `SELECT avatar AS url FROM accounts
        WHERE avatar IS NOT NULL AND avatar <> ''
       UNION ALL
       SELECT url FROM messages
        WHERE type = 'sticker' AND url IS NOT NULL AND url <> ''`,
    );
    for (const row of durableUrls) {
      referencedMedia.add(durableMediaIdentity(row.url));
    }

    let deleted = 0;
    for (const candidate of candidates) {
      const idIdentity = /^up_[A-Za-z0-9_-]{8,}$/.test(candidate.id)
        ? `upload:${candidate.id}`
        : undefined;
      if (
        (idIdentity && referencedMedia.has(idIdentity)) ||
        referencedMedia.has(durableMediaIdentity(candidate.url))
      ) {
        continue;
      }
      const removed = await db.run(
        `DELETE FROM uploads
          WHERE id = ? AND purpose IN ('avatar', 'sticker') AND message_id IS NULL`,
        [candidate.id],
      );
      if (removed !== 1) continue;
      const stillReferenced = await db.get<{ exists: boolean }>(
        "SELECT EXISTS (SELECT 1 FROM uploads WHERE path = ?) AS exists",
        [candidate.path],
      );
      if (!stillReferenced?.exists) {
        await db.run(
          `INSERT INTO file_cleanup_queue (id, path, reason, created_at)
           VALUES (?, ?, 'unreferenced_shared_upload', ?)`,
          [`cleanup_${nanoid(16)}`, candidate.path, now],
        );
      }
      deleted += 1;
    }
    return deleted;
  });
  if (queued > 0) console.info(`[upload] 已将 ${queued} 个无引用头像/贴纸加入持久清理队列`);
  return queued;
}

/** 清理崩溃遗留的 `.<name>.uploading` 临时文件（UPLOAD-001）。 */
export async function cleanupStaleUploadingFiles(now = Date.now()): Promise<number> {
  let removed = 0;
  try {
    const entries = await fs.readdir(config.uploadDir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!entry.name.startsWith(".") || !entry.name.endsWith(".uploading")) continue;
      const fullPath = path.join(config.uploadDir, entry.name);
      if (!isPathInsideUploadDir(fullPath)) continue;
      try {
        const stat = await fs.stat(fullPath);
        if (now - stat.mtimeMs < UPLOADING_STALE_MS) continue;
        await fs.rm(fullPath, { force: true });
        removed += 1;
      } catch {
        // 单个文件失败不阻断批次
      }
    }
  } catch (error) {
    console.warn(`[upload] 扫描 .uploading 失败: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (removed > 0) console.info(`[upload] 已清理 ${removed} 个过期 .uploading 临时文件`);
  return removed;
}

export function startUploadCleanup(): () => void {
  const runCleanup = () => {
    void (async () => {
      const results = await Promise.allSettled([
        cleanupAbandonedMessageUploads(),
        cleanupUnreferencedSharedUploads(),
        cleanupStaleUploadingFiles(),
      ]);
      await drainFileCleanupQueue();
      const failed = results.find((result) => result.status === "rejected");
      if (failed?.status === "rejected") throw failed.reason;
    })().catch((error) => {
      console.warn(`[upload] 定时清理失败: ${error instanceof Error ? error.message : String(error)}`);
    });
  };
  runCleanup();
  const timer = setInterval(runCleanup, CLEANUP_INTERVAL_MS);
  timer.unref();
  return () => clearInterval(timer);
}
