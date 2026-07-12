import { reconcileMemoryLifecycle, repairMissingMemoryEmbeddings } from "./store";

let running = false;
let timer: NodeJS.Timeout | null = null;

async function maintain(): Promise<void> {
  if (running) return;
  running = true;
  try {
    const result = await reconcileMemoryLifecycle();
    const repairedEmbeddings = await repairMissingMemoryEmbeddings();
    if (result.expired || result.retracted) {
      console.log(`[memory] 生命周期维护 expired=${result.expired} retracted=${result.retracted}`);
    }
    if (repairedEmbeddings) console.log(`[memory] 补齐 embedding=${repairedEmbeddings}`);
  } catch (error) {
    console.warn("[memory] 生命周期维护失败:", error instanceof Error ? error.message : error);
  } finally {
    running = false;
  }
}

export function startMemoryMaintenance(): void {
  if (timer) return;
  void maintain();
  timer = setInterval(() => void maintain(), 60 * 60 * 1000);
}

export function stopMemoryMaintenance(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
