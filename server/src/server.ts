import { Server } from "socket.io";
import { buildApp } from "./app";
import { config } from "./config";
import { initDatabase } from "./db";
import { seedAccounts } from "./auth/accounts";
import { registerRealtime } from "./socket/realtime";

async function main() {
  await initDatabase();
  await seedAccounts();

  const app = await buildApp();
  const io = new Server(app.server, {
    cors: {
      origin: true,
    },
  });
  registerRealtime(io);

  await app.listen({ host: config.host, port: config.port });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
