import fs from "node:fs";
import path from "node:path";
import cors from "@fastify/cors";
import multipart from "@fastify/multipart";
import Fastify from "fastify";
import { config } from "./config";
import { registerAuthRoutes } from "./auth/routes";
import { registerDeviceRoutes } from "./auth/deviceRoutes";
import { registerUploadRoutes } from "./upload/routes";
import { registerPersonalItemRoutes, type PersonalItemRouteEvents } from "./personalItems/routes";
import { registerSyncRoutes } from "./sync/routes";
import { registerMediaAccessRoutes } from "./upload/mediaAccess";
import { pingDatabase } from "./db";
import { registerAiDebugRoutes } from "./ai/debug/routes";
import { registerAiMcpRoutes } from "./ai/mcp/routes";
import { registerMemoryRoutes } from "./ai/memory/routes";
import { registerSyncV2Routes } from "./sync/v2Routes";
import { errorCodeFor } from "./errors/errorCodes";
import { registerTranscriptionRoutes } from "./transcription/routes";
import { registerAlbumRoutes } from "./albums/routes";
import { registerCalendarRoutes } from "./calendar/routes";
import { registerPetRoutes } from "./pet/routes";
import { registerStatsRoutes } from "./stats/routes";
import { registerRecommendationRoutes } from "./daily/routes";

export interface AppDependencies {
  personalItemEvents?: PersonalItemRouteEvents;
}

export async function buildApp(dependencies: AppDependencies = {}) {
  fs.mkdirSync(config.uploadDir, { recursive: true });

  const app = Fastify({
    logger: {
      level: config.isProduction ? "info" : "debug",
    },
  });

  app.setErrorHandler((error, request, reply) => {
    const errorCode = errorCodeFor(error);
    const candidate = error as { statusCode?: unknown };
    const statusCode = typeof candidate.statusCode === "number" ? candidate.statusCode : 500;
    request.log.warn({ errorCode, statusCode }, "request failed");
    return reply.code(statusCode).send({ error: errorCode });
  });

  // 原生 App 不依赖浏览器 CORS；生产收紧，避免任意网页源带 token 调 API。
  await app.register(cors, {
    origin: config.isProduction
      ? [config.publicBaseURL, new URL(config.publicBaseURL).origin]
      : true,
  });
  await app.register(multipart, {
    limits: {
      fileSize: 50 * 1024 * 1024,
      files: 1,
    },
  });
  const readiness = async (_request: unknown, reply: { code(status: number): { send(value: unknown): unknown } }) => {
    try {
      await pingDatabase();
      return { ok: true, database: "ok", ts: Date.now() };
    } catch {
      return reply.code(503).send({ ok: false, database: "unavailable", ts: Date.now() });
    }
  };
  app.get("/live", async () => ({ ok: true, process: "alive", ts: Date.now() }));
  app.get("/ready", readiness);
  app.get("/health", readiness);
  app.get("/assets/couplechat-icon.png", async (_request, reply) => {
    reply.header("Cache-Control", "public, max-age=604800, immutable");
    return reply.type("image/png").send(
      fs.createReadStream(path.join(process.cwd(), "assets", "couplechat-icon.png")),
    );
  });

  await registerAuthRoutes(app);
  await registerDeviceRoutes(app);
  await registerMediaAccessRoutes(app);
  await registerUploadRoutes(app);
  await registerPersonalItemRoutes(app, dependencies.personalItemEvents);
  await registerSyncRoutes(app);
  await registerSyncV2Routes(app);
  await registerMemoryRoutes(app);
  await registerTranscriptionRoutes(app);
  await registerAlbumRoutes(app);
  await registerCalendarRoutes(app);
  await registerPetRoutes(app);
  await registerStatsRoutes(app);
  await registerRecommendationRoutes(app);
  await registerAiMcpRoutes(app);
  await registerAiDebugRoutes(app);

  return app;
}
