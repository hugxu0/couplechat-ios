import { Server } from "socket.io";
import { buildApp } from "./app";
import { config } from "./config";
import { closeDatabase, initDatabase } from "./db";
import { seedAccounts } from "./auth/accounts";
import { registerRealtime } from "./socket/realtime";
import { initAi, setAiSocketIO, shutdownAi } from "./ai";
import { createReminderScheduler } from "./personalItems/reminderScheduler";
import { startUploadCleanup } from "./upload/cleanup";
import { socketEvents } from "./contracts/realtime";
import { shutdownServer } from "./lifecycle/shutdown";
import { createTranscriptScheduler } from "./transcription/scheduler";
import { createRecommendationScheduler } from "./daily/scheduler";
import { createDiaryScheduler } from "./ai/diary/scheduler";

async function main() {
  await initDatabase();
  await seedAccounts();
  await initAi();

  let io: Server | null = null;
  const app = await buildApp({
    personalItemEvents: {
      sharedItemChanged(action, item) {
        const value = item as { scope?: string; coupleId?: string } | null;
        if (value?.scope === "shared" && value.coupleId) {
          io?.to(`couple:${value.coupleId}`).emit(socketEvents.personalItemChanged, { action, item });
        }
      },
    },
  });
  io = new Server(app.server, { cors: { origin: true } });
  setAiSocketIO(io);
  registerRealtime(io);

  const reminderScheduler = createReminderScheduler();
  const transcriptScheduler = createTranscriptScheduler();
  const recommendationScheduler = createRecommendationScheduler();
  const diaryScheduler = createDiaryScheduler();
  if (config.scheduledJobsEnabled) {
    reminderScheduler.start();
    transcriptScheduler.start();
    recommendationScheduler.start();
    diaryScheduler.start();
  }
  await app.listen({ host: config.host, port: config.port });
  const stopUploadCleanup = config.scheduledJobsEnabled ? startUploadCleanup() : () => undefined;

  let shuttingDown = false;
  const shutdown = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    try {
      await shutdownServer({
        stopSchedulers: () => {
          reminderScheduler.stop();
          transcriptScheduler.stop();
          recommendationScheduler.stop();
          diaryScheduler.stop();
          shutdownAi();
        },
        stopUploadCleanup,
        closeSocket: () => new Promise((resolve) => io?.close(() => resolve()) ?? resolve()),
        closeHttp: () => app.close(),
        closeDatabase,
      });
      process.exit(0);
    } catch (error) {
      console.error("[shutdown] 关闭失败:", error);
      process.exit(1);
    }
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
