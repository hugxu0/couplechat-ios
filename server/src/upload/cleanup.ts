import fs from "node:fs/promises";
import path from "node:path";
import { all, run, type UploadRow } from "../db";
import { config } from "../config";

const ABANDONED_AFTER_MS = 24 * 60 * 60 * 1000;
const UPLOADING_STALE_MS = 2 * 60 * 60 * 1000;
const CLEANUP_INTERVAL_MS = 6 * 60 * 60 * 1000;
const BATCH_SIZE = 500;

interface FileCleanupRow {
  id: string;
  path: string;
  attempt_count: number;
}

function isPathInsideUploadDir(candidate: string): boolean {
  const resolved = path.resolve(candidate);
  const root = path.resolve(config.uploadDir);
  return resolved === root || resolved.startsWith(root + path.sep);
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
      await fs.rm(row.path, { force: true });
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
  const rows = await all<UploadRow>(
    `SELECT upload.* FROM uploads upload
      WHERE upload.purpose IN ('message', 'album') AND upload.message_id IS NULL
        AND upload.created_at < ?
        AND NOT EXISTS (SELECT 1 FROM media_assets asset WHERE asset.source_upload_id = upload.id)
      ORDER BY created_at ASC LIMIT ?`,
    [now - ABANDONED_AFTER_MS, BATCH_SIZE],
  );
  let removed = 0;
  for (const row of rows) {
    try {
      if (isPathInsideUploadDir(row.path)) {
        await fs.rm(row.path, { force: true });
      }
      removed += await run(
        `DELETE FROM uploads upload WHERE upload.id = ?
           AND upload.purpose IN ('message', 'album') AND upload.message_id IS NULL
           AND NOT EXISTS (SELECT 1 FROM media_assets asset WHERE asset.source_upload_id = upload.id)`,
        [row.id],
      );
    } catch (error) {
      console.warn(`[upload] 清理失败 id=${row.id}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (removed > 0) console.info(`[upload] 已清理 ${removed} 个未绑定附件`);
  return removed;
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
    void Promise.all([
      drainFileCleanupQueue(),
      cleanupAbandonedMessageUploads(),
      cleanupStaleUploadingFiles(),
    ]).catch((error) => {
      console.warn(`[upload] 定时清理失败: ${error instanceof Error ? error.message : String(error)}`);
    });
  };
  runCleanup();
  const timer = setInterval(runCleanup, CLEANUP_INTERVAL_MS);
  timer.unref();
  return () => clearInterval(timer);
}
