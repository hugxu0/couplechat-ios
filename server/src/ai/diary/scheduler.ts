import { ensureYesterdayDiary } from "./service";

export interface DiaryScheduler {
  start(): void;
  stop(): void;
  tick(): Promise<boolean>;
}

/** 约每小时尝试一次；幂等，已有日记则跳过生成。 */
export function createDiaryScheduler(intervalMs = 60 * 60 * 1_000): DiaryScheduler {
  let timer: NodeJS.Timeout | null = null;
  let running = false;

  const tick = async (): Promise<boolean> => {
    if (running) return false;
    running = true;
    try {
      const diary = await ensureYesterdayDiary();
      return Boolean(diary);
    } catch (error) {
      console.warn("[diary] 调度失败:", error instanceof Error ? error.message : error);
      return false;
    } finally {
      running = false;
    }
  };

  return {
    start() {
      if (timer) return;
      void tick();
      timer = setInterval(() => void tick(), Math.max(60_000, intervalMs));
    },
    stop() {
      if (timer) clearInterval(timer);
      timer = null;
    },
    tick,
  };
}
