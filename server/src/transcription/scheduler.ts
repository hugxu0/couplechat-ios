import { createConfiguredTranscriptionProvider } from "./provider";
import { runTranscriptWorkerOnce, type TranscriptionProvider } from "./service";

export interface TranscriptScheduler {
  start(): void;
  stop(): void;
  tick(): Promise<boolean>;
}

export function createTranscriptScheduler(
  provider: TranscriptionProvider | null = createConfiguredTranscriptionProvider(),
  intervalMs = Math.max(1_000, Number(process.env.TRANSCRIPTION_POLL_INTERVAL_MS ?? 10_000)),
): TranscriptScheduler {
  let timer: NodeJS.Timeout | null = null;
  let running = false;
  const tick = async () => {
    if (!provider || running) return false;
    running = true;
    try {
      let processed = false;
      // 每次最多排空 10 条，兼顾启动追赶和事件循环公平性。
      for (let index = 0; index < 10; index += 1) {
        const found = await runTranscriptWorkerOnce(provider);
        if (!found) break;
        processed = true;
      }
      return processed;
    } catch (error) {
      console.warn(`[transcription] worker failed: ${error instanceof Error ? error.message : String(error)}`);
      return false;
    } finally {
      running = false;
    }
  };
  return {
    start() {
      if (!provider || timer) return;
      void tick();
      timer = setInterval(() => void tick(), intervalMs);
      timer.unref();
    },
    stop() {
      if (timer) clearInterval(timer);
      timer = null;
    },
    tick,
  };
}
