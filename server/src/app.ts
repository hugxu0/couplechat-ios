import fs from "node:fs";
import path from "node:path";
import cors from "@fastify/cors";
import multipart from "@fastify/multipart";
import fastifyStatic from "@fastify/static";
import Fastify from "fastify";
import { config } from "./config";
import { registerAuthRoutes } from "./auth/routes";
import { registerUploadRoutes } from "./upload/routes";
import { registerStatsRoutes } from "./stats/routes";

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
  await app.register(fastifyStatic, {
    root: path.resolve(config.uploadDir),
    prefix: "/uploads/",
  });

  app.get("/health", async () => ({ ok: true, ts: Date.now() }));

  await registerAuthRoutes(app);
  await registerUploadRoutes(app);
  await registerStatsRoutes(app);

  return app;
}
