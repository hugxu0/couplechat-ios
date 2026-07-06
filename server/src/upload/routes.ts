import fs from "node:fs";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import type { FastifyInstance } from "fastify";
import { nanoid } from "nanoid";
import { run } from "../db";
import { config } from "../config";
import { requireAuth } from "../auth/httpAuth";

const allowedMime = new Set(["image/jpeg", "image/png", "image/gif", "image/webp", "video/mp4", "video/quicktime"]);

function extensionFor(mimeType: string) {
  switch (mimeType) {
    case "image/jpeg": return ".jpg";
    case "image/png": return ".png";
    case "image/gif": return ".gif";
    case "image/webp": return ".webp";
    case "video/mp4": return ".mp4";
    case "video/quicktime": return ".mov";
    default: return "";
  }
}

export async function registerUploadRoutes(app: FastifyInstance) {
  fs.mkdirSync(config.uploadDir, { recursive: true });

  app.post("/api/upload", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });

    const file = await request.file();
    if (!file) return reply.code(400).send({ error: "file_required" });
    if (!allowedMime.has(file.mimetype)) return reply.code(415).send({ error: "unsupported_media_type" });

    const id = `up_${nanoid(16)}`;
    const filename = `${id}${extensionFor(file.mimetype)}`;
    const fullPath = path.join(config.uploadDir, filename);
    await pipeline(file.file, fs.createWriteStream(fullPath));

    const stat = fs.statSync(fullPath);
    const url = `${config.publicBaseURL}/uploads/${filename}`;

    run(
      `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [id, request.user.username, fullPath, url, file.mimetype, stat.size, Date.now()],
    );

    return {
      id,
      url,
      mimeType: file.mimetype,
      size: stat.size,
      type: file.mimetype.startsWith("video/") ? "video" : "image",
    };
  });
}
