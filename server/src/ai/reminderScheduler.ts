// 到点提醒扫描：定时扫 personal_items 表，把到点的未完成提醒推送给主人（Bark）。
// 内存里记 lastScanTs 游标，启动时初始化为「现在」——别回推服务挂掉之前攒下的旧提醒。

import type { Server } from "socket.io";
import { all, get, type AccountRow, type PersonalItemRow } from "../db";
import { sendBarkPush } from "../push/bark";
import { config } from "../config";

const SCAN_INTERVAL_MS = 60_000;

let lastScanTs = Date.now();
let timer: NodeJS.Timeout | null = null;
let running = false;

async function scanOnce(io: Server) {
  if (running) return;
  running = true;
  try {
    const now = Date.now();
    const due = await all<PersonalItemRow>(
      `SELECT * FROM personal_items
       WHERE kind = 'reminder' AND is_done = 0
         AND due_at IS NOT NULL AND due_at > ? AND due_at <= ?`,
      [lastScanTs, now],
    );

    for (const reminder of due) {
      const owner = await get<AccountRow>("SELECT * FROM accounts WHERE username = ?", [reminder.owner]);
      if (!owner?.bark_key) continue;
      const dueAt = reminder.due_at ?? 0;
      if (!dueAt) continue;
      const dt = new Date(dueAt + 8 * 60 * 60 * 1000);
      const p = (n: number) => String(n).padStart(2, "0");
      const timeLabel = `${p(dt.getUTCHours())}:${p(dt.getUTCMinutes())}`;
      const body = `${reminder.title} · ${timeLabel}`;
      await sendBarkPush(owner.bark_key, "大橘提醒你", body).catch(() => {});
    }

    lastScanTs = now;
  } catch (error) {
    console.warn("[reminder] 扫描失败:", error instanceof Error ? error.message : error);
  } finally {
    running = false;
  }
}

export function startReminderScheduler(io: Server) {
  if (timer) return;
  lastScanTs = Date.now();
  void scanOnce(io).catch(() => {});
  timer = setInterval(() => {
    void scanOnce(io).catch(() => {});
  }, SCAN_INTERVAL_MS);
  console.log("[reminder] 到点提醒扫描已启动（60s 间隔）");
}

export function stopReminderScheduler() {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
}