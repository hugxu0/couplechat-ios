import { flushMemory } from "../ai/memory/extractor";
import { ensureTodayRecommendation } from "./recommendationService";

export interface RecommendationScheduler {
  start(): void;
  stop(): void;
  tick(): Promise<boolean>;
}

export function createRecommendationScheduler(
  intervalMs = 15 * 60 * 1_000,
): RecommendationScheduler {
  let timer: NodeJS.Timeout | null = null;
  let running = false;

  const tick = async (): Promise<boolean> => {
    if (running) return false;
    running = true;
    try {
      const item = await ensureTodayRecommendation(
        { username: "xu", name: "小旭" },
        () => flushMemory("couple"),
      );
      return Boolean(item);
    } catch (error) {
      console.warn("[recommendation] 每日推荐生成失败:", error instanceof Error ? error.message : error);
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
