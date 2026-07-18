import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { config } from "../config";
import { get, type UploadRow } from "../db";

const mediaParamsSchema = z.object({ id: z.string().regex(/^up_[A-Za-z0-9_-]{8,}$/) });
// 新后端使用 up_<id>，旧网页后端使用 <13位毫秒时间戳>-<12位hex>。
// 两种都必须先命中 uploads 表，绝不把任意磁盘文件暴露成静态目录。
const legacyParamsSchema = z.object({
  filename: z.string().regex(/^(?:up_[A-Za-z0-9_-]{8,}|[0-9]{13}-[a-f0-9]{12})\.[a-z0-9]{1,8}$/i),
});
const signatureQuerySchema = z.object({
  sig: z.string().min(32).max(128),
  exp: z.coerce.number().int().positive().optional(),
});

function hmacWith(secret: string, payload: string): string {
  return crypto.createHmac("sha256", secret).update(payload).digest("base64url");
}

function timingSafeEqualString(expected: string, actual: string): boolean {
  const left = Buffer.from(expected);
  const right = Buffer.from(actual);
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

/** 新格式：HMAC(mediaSecret, `media:{id}:{exp}`) */
export function signMediaId(id: string, expMs?: number): { sig: string; exp: number } {
  const exp = expMs ?? Date.now() + config.mediaUrlTtlSeconds * 1000;
  const sig = hmacWith(config.mediaSigningSecret, `media:${id}:${exp}`);
  return { sig, exp };
}

export function verifyMediaSignature(id: string, signature: string, expMs?: number): boolean {
  if (typeof expMs === "number") {
    if (!Number.isFinite(expMs) || expMs < Date.now()) return false;
    const expected = hmacWith(config.mediaSigningSecret, `media:${id}:${expMs}`);
    if (timingSafeEqualString(expected, signature)) return true;
    // 若密钥已拆分，仍接受用 TOKEN_SECRET 签的短期签名（轮换过渡）。
    if (config.mediaSigningSecret !== config.tokenSecret) {
      const legacySecret = hmacWith(config.tokenSecret, `media:${id}:${expMs}`);
      if (timingSafeEqualString(legacySecret, signature)) return true;
    }
    return false;
  }

  // 历史永久签名：media:{id}，无 exp。新消息不再签发，仅兼容库内旧 URL。
  const permanentMedia = hmacWith(config.mediaSigningSecret, `media:${id}`);
  if (timingSafeEqualString(permanentMedia, signature)) return true;
  if (config.mediaSigningSecret !== config.tokenSecret) {
    const permanentToken = hmacWith(config.tokenSecret, `media:${id}`);
    if (timingSafeEqualString(permanentToken, signature)) return true;
  }
  return false;
}

export function signedMediaURL(id: string, options?: { ttlSeconds?: number }): string {
  const ttlSeconds = options?.ttlSeconds ?? config.mediaUrlTtlSeconds;
  const { sig, exp } = signMediaId(id, Date.now() + ttlSeconds * 1000);
  return `${config.publicBaseURL}/media/${id}?sig=${sig}&exp=${exp}`;
}

/** AI 出站看图使用更短 TTL。 */
export function signedMediaURLForAi(id: string): string {
  return signedMediaURL(id, { ttlSeconds: config.mediaAiUrlTtlSeconds });
}

const MEDIA_ID_IN_URL = /\/media\/(up_[A-Za-z0-9_-]{8,})(?:\?|$)/;

/** 从历史 URL 提取 upload id，按需重签（读路径刷新 TTL，避免库内过期签名）。 */
export function refreshSignedMediaUrl(
  url: string | null | undefined,
  options?: { forAi?: boolean },
): string | undefined {
  if (!url) return undefined;
  const match = MEDIA_ID_IN_URL.exec(url);
  if (!match?.[1]) return url;
  return options?.forAi ? signedMediaURLForAi(match[1]) : signedMediaURL(match[1]);
}

export function refreshSignedMediaUrls(
  urls: string[],
  options?: { forAi?: boolean },
): string[] {
  return [...new Set(urls.map((url) => refreshSignedMediaUrl(url, options) ?? url).filter(Boolean))];
}

export function parseRequestedByteRange(value: string | undefined, size: number): { start: number; end: number } | null {
  if (!value) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(value.trim());
  if (!match) return null;
  if (!match[1]) {
    const suffixLength = Number(match[2]);
    if (!Number.isSafeInteger(suffixLength) || suffixLength <= 0) return null;
    return { start: Math.max(0, size - suffixLength), end: size - 1 };
  }
  const start = Number(match[1]);
  const end = match[2] ? Number(match[2]) : size - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start > end || start >= size) {
    return null;
  }
  return { start, end: Math.min(end, size - 1) };
}

function requestedByteRange(request: FastifyRequest, size: number): { start: number; end: number } | null {
  return parseRequestedByteRange(request.headers.range, size);
}

function sendUpload(request: FastifyRequest, reply: FastifyReply, upload: UploadRow) {
  const filename = path.basename(upload.path).replace(/["\r\n]/g, "_");
  const range = requestedByteRange(request, upload.size);
  reply
    .type(upload.mime_type)
    .header("Accept-Ranges", "bytes")
    .header("Content-Disposition", `inline; filename="${filename}"`)
    .header("X-Content-Type-Options", "nosniff")
    .header("Cache-Control", "private, max-age=3600");
  if (range) {
    reply
      .code(206)
      .header("Content-Length", String(range.end - range.start + 1))
      .header("Content-Range", `bytes ${range.start}-${range.end}/${upload.size}`);
    return reply.send(fs.createReadStream(upload.path, range));
  }
  reply.header("Content-Length", String(upload.size));
  return reply.send(fs.createReadStream(upload.path));
}

export async function registerMediaAccessRoutes(app: FastifyInstance) {
  app.get("/media/:id", async (request, reply) => {
    const params = mediaParamsSchema.safeParse(request.params);
    const query = signatureQuerySchema.safeParse(request.query);
    if (!params.success || !query.success || !verifyMediaSignature(params.data.id, query.data.sig, query.data.exp)) {
      return reply.code(404).send({ error: "not_found" });
    }
    const upload = await get<UploadRow>("SELECT * FROM uploads WHERE id = ?", [params.data.id]);
    if (!upload || !fs.existsSync(upload.path)) return reply.code(404).send({ error: "not_found" });
    return sendUpload(request, reply, upload);
  });

  // 历史消息继续使用旧 URL；只允许数据库中确实以 /uploads/ 保存的旧记录，
  // 新签名媒体即使文件名被看到也不能从该路径绕过签名。
  app.get("/uploads/:filename", async (request, reply) => {
    const params = legacyParamsSchema.safeParse(request.params);
    if (!params.success) return reply.code(404).send({ error: "not_found" });
    const upload = await get<UploadRow>("SELECT * FROM uploads WHERE url LIKE ? LIMIT 1", [
      `%/uploads/${params.data.filename}`,
    ]);
    if (!upload || path.basename(upload.path) !== params.data.filename || !fs.existsSync(upload.path)) {
      return reply.code(404).send({ error: "not_found" });
    }
    return sendUpload(request, reply, upload);
  });
}
