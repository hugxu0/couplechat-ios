import { Server } from "socket.io";
import { buildApp } from "./app";
import { config } from "./config";
import { initDatabase } from "./db";
import { seedAccounts } from "./auth/accounts";
import { registerRealtime } from "./socket/realtime";
import { setSocketIO } from "./personalItems/routes";
import { initAi } from "./ai/aiService";
import { startReminderScheduler } from "./ai/reminderScheduler";

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
  setSocketIO(io);
  registerRealtime(io);
  startReminderScheduler(io);

  await app.listen({ host: config.host, port: config.port });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
