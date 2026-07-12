import { ensureRecommendation, generateDiary } from "./dailyContent";
import { DAY_ROLLOVER_HOUR } from "../settings";
import { aiEnabled } from "../provider";
import { addDays, beijingParts, cycleDate } from "../time";

let running = false;
let initialTimer: NodeJS.Timeout | null = null;
let intervalTimer: NodeJS.Timeout | null = null;

async function maintainDailyContent(): Promise<void> {
  if (running || !aiEnabled()) return;
  running = true;
  try {
    await generateDiary(addDays(cycleDate(), -1)).catch((error) => {
      console.warn("[ai] 每日日记生成失败:", error instanceof Error ? error.message : error);
    });
    await ensureRecommendation(cycleDate()).catch((error) => {
      console.warn("[ai] 每日推荐生成失败:", error instanceof Error ? error.message : error);
    });
  } finally {
    running = false;
  }
}

export function startDailyScheduler(): void {
  if (initialTimer || intervalTimer) return;
  initialTimer = setTimeout(() => {
    initialTimer = null;
    void maintainDailyContent();
  }, 30_000);
  let lastRun = "";
  intervalTimer = setInterval(() => {
    const now = beijingParts();
    const date = cycleDate();
    if (now.hour === DAY_ROLLOVER_HOUR && now.minute <= 5 && lastRun !== date) {
      lastRun = date;
      void maintainDailyContent();
    }
  }, 60_000);
}

export function stopDailyScheduler(): void {
  if (initialTimer) clearTimeout(initialTimer);
  if (intervalTimer) clearInterval(intervalTimer);
  initialTimer = null;
  intervalTimer = null;
}
