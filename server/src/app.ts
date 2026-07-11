import fs from "node:fs";
import cors from "@fastify/cors";
import multipart from "@fastify/multipart";
import Fastify from "fastify";
import { config } from "./config";
import { registerAuthRoutes } from "./auth/routes";
import { registerUploadRoutes } from "./upload/routes";
import { registerStatsRoutes } from "./stats/routes";
import { registerPersonalItemRoutes } from "./personalItems/routes";
import { registerSyncRoutes } from "./sync/routes";
import { registerMediaAccessRoutes } from "./upload/mediaAccess";
import { pingDatabase } from "./db";
import { registerAiDebugRoutes } from "./ai/debug/routes";
import { registerAiMcpRoutes } from "./ai/mcp/routes";

export async function buildApp() {
  fs.mkdirSync(config.uploadDir, { recursive: true });

  const app = Fastify({
    logger: {
      level: config.isProduction ? "info" : "debug",
    },
  });

  await app.register(cors, { origin: true });
  await app.register(multipart, {
    limits: {
      fileSize: 50 * 1024 * 1024,
      files: 1,
    },
  });
  app.get("/health", async (_request, reply) => {
    try {
      await pingDatabase();
      return { ok: true, database: "ok", ts: Date.now() };
    } catch {
      return reply.code(503).send({ ok: false, database: "unavailable", ts: Date.now() });
    }
  });

  await registerAuthRoutes(app);
  await registerMediaAccessRoutes(app);
  await registerUploadRoutes(app);
  await registerStatsRoutes(app);
  await registerPersonalItemRoutes(app);
  await registerSyncRoutes(app);
  await registerAiMcpRoutes(app);
  await registerAiDebugRoutes(app);

  return app;
}
