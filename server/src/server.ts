import { Server } from "socket.io";
import { buildApp } from "./app";
import { config } from "./config";
import { initDatabase, closeDatabase } from "./db";
import { seedAccounts } from "./auth/accounts";
import { registerRealtime } from "./socket/realtime";
import { setSocketIO } from "./personalItems/routes";
import { initAi, setAiSocketIO } from "./ai";
import { startReminderScheduler } from "./personalItems/reminderScheduler";
import { startUploadCleanup } from "./upload/cleanup";

async function main() {
  await initDatabase();
  await seedAccounts();
  await initAi();

  const app = await buildApp();
  const io = new Server(app.server, {
    cors: {
      origin: true,
    },
  });
  setAiSocketIO(io);
  setSocketIO(io);
  registerRealtime(io);
  startReminderScheduler();

  await app.listen({ host: config.host, port: config.port });
  const stopUploadCleanup = startUploadCleanup();

  const shutdown = () => {
    stopUploadCleanup();
    void closeDatabase().finally(() => process.exit(0));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
