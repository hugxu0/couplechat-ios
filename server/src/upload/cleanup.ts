import fs from "node:fs/promises";
import { all, run, type UploadRow } from "../db";

const ABANDONED_AFTER_MS = 24 * 60 * 60 * 1000;
const CLEANUP_INTERVAL_MS = 6 * 60 * 60 * 1000;
const BATCH_SIZE = 500;

export async function cleanupAbandonedMessageUploads(now = Date.now()): Promise<number> {
  const rows = await all<UploadRow>(
    `SELECT * FROM uploads
      WHERE purpose = 'message' AND message_id IS NULL AND created_at < ?
      ORDER BY created_at ASC LIMIT ?`,
    [now - ABANDONED_AFTER_MS, BATCH_SIZE],
  );
  let removed = 0;
  for (const row of rows) {
    try {
      await fs.rm(row.path, { force: true });
      removed += await run(
        "DELETE FROM uploads WHERE id = ? AND purpose = 'message' AND message_id IS NULL",
        [row.id],
      );
    } catch (error) {
      console.warn(`[upload] 清理失败 id=${row.id}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (removed > 0) console.info(`[upload] 已清理 ${removed} 个未绑定附件`);
  return removed;
}

export function startUploadCleanup(): () => void {
  const runCleanup = () => {
    void cleanupAbandonedMessageUploads().catch((error) => {
      console.warn(`[upload] 定时清理失败: ${error instanceof Error ? error.message : String(error)}`);
    });
  };
  runCleanup();
  const timer = setInterval(runCleanup, CLEANUP_INTERVAL_MS);
  timer.unref();
  return () => clearInterval(timer);
}
