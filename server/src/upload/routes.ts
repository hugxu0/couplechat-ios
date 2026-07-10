import fs from "node:fs";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import type { FastifyInstance } from "fastify";
import { nanoid } from "nanoid";
import { z } from "zod";
import { run } from "../db";
import { config } from "../config";
import { requireAuth } from "../auth/httpAuth";
import { signedMediaURL } from "./mediaAccess";

const allowedMime = new Set([
  "image/jpeg", "image/png", "image/gif", "image/webp",
  "video/mp4", "video/quicktime",
  "audio/m4a", "audio/x-m4a", "audio/mp4", "audio/aac",
  "application/pdf", "application/zip", "application/x-zip-compressed",
  "application/json", "application/octet-stream",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.ms-powerpoint",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "text/plain", "text/markdown", "text/csv",
]);

const uploadQuerySchema = z.object({
  // legacy 保证旧客户端滚动升级安全；只有明确标记为 message 的未绑定上传会被定期清理。
  purpose: z.enum(["message", "avatar", "sticker", "legacy"]).default("legacy"),
});

function extensionFor(mimeType: string) {
  switch (mimeType) {
    case "image/jpeg": return ".jpg";
    case "image/png": return ".png";
    case "image/gif": return ".gif";
    case "image/webp": return ".webp";
    case "video/mp4": return ".mp4";
    case "video/quicktime": return ".mov";
    case "audio/m4a": case "audio/x-m4a": case "audio/mp4": case "audio/aac": return ".m4a";
    case "application/pdf": return ".pdf";
    case "application/zip": case "application/x-zip-compressed": return ".zip";
    case "application/json": return ".json";
    case "application/msword": return ".doc";
    case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return ".docx";
    case "application/vnd.ms-excel": return ".xls";
    case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return ".xlsx";
    case "application/vnd.ms-powerpoint": return ".ppt";
    case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return ".pptx";
    case "text/plain": return ".txt";
    case "text/markdown": return ".md";
    case "text/csv": return ".csv";
    default: return ".bin";
  }
}

function typeFor(mimeType: string) {
  if (mimeType.startsWith("video/")) return "video";
  if (mimeType.startsWith("audio/")) return "voice";
  if (mimeType.startsWith("image/")) return "image";
  return "file";
}

function hasExpectedSignature(filePath: string, mimeType: string): boolean {
  const buffer = Buffer.alloc(16);
  const fd = fs.openSync(filePath, "r");
  let bytesRead = 0;
  try {
    bytesRead = fs.readSync(fd, buffer, 0, buffer.length, 0);
  } finally {
    fs.closeSync(fd);
  }
  const ascii = buffer.subarray(0, bytesRead).toString("ascii");
  const isZipBased = mimeType === "application/zip" ||
    mimeType === "application/x-zip-compressed" ||
    mimeType.includes("openxmlformats-officedocument");
  if (mimeType === "image/jpeg") return bytesRead >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff;
  if (mimeType === "image/png") return bytesRead >= 8 && buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  if (mimeType === "image/gif") return ascii.startsWith("GIF87a") || ascii.startsWith("GIF89a");
  if (mimeType === "image/webp") return ascii.startsWith("RIFF") && ascii.slice(8, 12) === "WEBP";
  if (mimeType === "video/mp4" || mimeType === "video/quicktime") return ascii.slice(4, 8) === "ftyp";
  if (mimeType === "application/pdf") return ascii.startsWith("%PDF-");
  if (isZipBased) return bytesRead >= 4 && buffer[0] === 0x50 && buffer[1] === 0x4b && [0x03, 0x05, 0x07].includes(buffer[2]);
  return true;
}

function invalidFileSignatureError() {
  return Object.assign(new Error("file_signature_mismatch"), { statusCode: 415 });
}

export async function registerUploadRoutes(app: FastifyInstance) {
  fs.mkdirSync(config.uploadDir, { recursive: true });

  app.post("/api/upload", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const query = uploadQuerySchema.safeParse(request.query ?? {});
    if (!query.success) return reply.code(400).send({ error: "invalid_upload_purpose" });

    const file = await request.file();
    if (!file) return reply.code(400).send({ error: "file_required" });
    if (!allowedMime.has(file.mimetype)) return reply.code(415).send({ error: "unsupported_media_type" });

    const id = `up_${nanoid(16)}`;
    const filename = `${id}${extensionFor(file.mimetype)}`;
    const fullPath = path.join(config.uploadDir, filename);
    const tempPath = path.join(config.uploadDir, `.${filename}.uploading`);
    try {
      // 先写入不可访问的临时文件；元数据落库成功后才发布签名媒体地址。
      await pipeline(file.file, fs.createWriteStream(tempPath, { flags: "wx" }));
      const stat = fs.statSync(tempPath);
      if (!hasExpectedSignature(tempPath, file.mimetype)) throw invalidFileSignatureError();
      const url = signedMediaURL(id);

      await run(
        `INSERT INTO uploads (id, owner, path, url, mime_type, size, created_at, purpose)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        [id, request.user.username, fullPath, url, file.mimetype, stat.size, Date.now(), query.data.purpose],
      );
      fs.renameSync(tempPath, fullPath);

      return {
        id,
        url,
        mimeType: file.mimetype,
        size: stat.size,
        type: typeFor(file.mimetype),
      };
    } catch (error) {
      // 上传中断、磁盘错误或数据库异常都不留下可访问的孤儿文件。
      fs.rmSync(tempPath, { force: true });
      fs.rmSync(fullPath, { force: true });
      await run("DELETE FROM uploads WHERE id = ?", [id]).catch(() => undefined);
      throw error;
    }

  });
}
