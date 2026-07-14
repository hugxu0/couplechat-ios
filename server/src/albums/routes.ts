import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "../auth/httpAuth";
import {
  addMessageMedia,
  addUploadedMedia,
  createAlbum,
  deleteAlbum,
  listAlbumItems,
  listAlbums,
  onThisDay,
  removeAlbumItem,
  updateAlbum,
  upsertMediaNote,
} from "./service";

const idParams = z.object({ albumId: z.string().min(1).max(128) });
const itemParams = idParams.extend({ itemId: z.string().min(1).max(128) });
const assetParams = z.object({ assetId: z.string().min(1).max(128) });
const albumBody = z.object({ title: z.string().trim().min(1).max(80), summary: z.string().trim().max(500).default("") });
const albumPatch = z.object({
  title: z.string().trim().min(1).max(80).optional(),
  summary: z.string().trim().max(500).optional(),
  coverAssetId: z.string().min(1).max(128).nullable().optional(),
  baseVersion: z.number().int().min(0),
}).refine((value) => value.title !== undefined || value.summary !== undefined || value.coverAssetId !== undefined);
const versionBody = z.object({ baseVersion: z.number().int().min(0) });
const pageQuery = z.object({ cursor: z.string().max(500).optional(), limit: z.coerce.number().int().min(1).max(100).default(30) });
const noteBody = z.object({ text: z.string().trim().max(2_000), baseVersion: z.number().int().min(0).optional() });
const onThisDayQuery = pageQuery.extend({
  timezone: z.string().min(1).max(80).default("Asia/Shanghai"),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
});

function validTimezone(timezone: string): boolean {
  try { new Intl.DateTimeFormat("en", { timeZone: timezone }).format(); return true; } catch { return false; }
}

function localDate(timezone: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts();
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}

export async function registerAlbumRoutes(app: FastifyInstance) {
  app.get("/api/v2/albums", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const query = pageQuery.safeParse(request.query);
    if (!query.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await listAlbums(request.user, query.data.cursor, query.data.limit);
    return result ?? reply.code(409).send({ error: "couple_required" });
  });

  app.post("/api/v2/albums", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const body = albumBody.safeParse(request.body);
    if (!body.success) return reply.code(400).send({ error: "invalid_request" });
    const album = await createAlbum(request.user, body.data);
    return album ? reply.code(201).send({ album }) : reply.code(409).send({ error: "couple_required" });
  });

  app.patch("/api/v2/albums/:albumId", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    const body = albumPatch.safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await updateAlbum(request.user, params.data.albumId, body.data);
    if (!result) return reply.code(404).send({ error: "not_found" });
    if ("invalidCover" in result && result.invalidCover) return reply.code(400).send({ error: "invalid_cover" });
    if ("conflict" in result && result.conflict) return reply.code(409).send({ error: "version_conflict", album: result.album });
    return { album: result.album };
  });

  app.delete("/api/v2/albums/:albumId", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    const body = versionBody.safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await deleteAlbum(request.user, params.data.albumId, body.data.baseVersion);
    if (!result) return reply.code(404).send({ error: "not_found" });
    if (result.conflict) return reply.code(409).send({ error: "version_conflict", album: result.album });
    return { ok: true };
  });

  app.get("/api/v2/albums/:albumId/items", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    const query = pageQuery.safeParse(request.query);
    if (!params.success || !query.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await listAlbumItems(request.user, params.data.albumId, query.data.cursor, query.data.limit);
    return result ?? reply.code(404).send({ error: "not_found" });
  });

  app.post("/api/v2/albums/:albumId/items/from-message", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    const body = z.object({ messageId: z.string().min(1).max(128) }).safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await addMessageMedia(request.user, params.data.albumId, body.data.messageId);
    if (!result || ("messageMissing" in result && result.messageMissing)) return reply.code(404).send({ error: "not_found" });
    if ("noMedia" in result && result.noMedia) return reply.code(400).send({ error: "message_has_no_album_media" });
    return reply.code(201).send(result);
  });

  app.post("/api/v2/albums/:albumId/items/from-upload", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    const body = z.object({
      uploadId: z.string().min(1).max(128),
      takenAt: z.number().int().positive().optional(),
      postId: z.string().trim().min(1).max(128).optional(),
    }).safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await addUploadedMedia(
      request.user,
      params.data.albumId,
      body.data.uploadId,
      body.data.takenAt ?? Date.now(),
      body.data.postId,
    );
    if (!result) return reply.code(404).send({ error: "not_found" });
    if (result.uploadMissing) return reply.code(404).send({ error: "upload_not_found" });
    if (result.noMedia) return reply.code(400).send({ error: "unsupported_album_media" });
    return reply.code(201).send(result);
  });

  app.delete("/api/v2/albums/:albumId/items/:itemId", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = itemParams.safeParse(request.params);
    if (!params.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await removeAlbumItem(request.user, params.data.albumId, params.data.itemId);
    return result ?? reply.code(404).send({ error: "not_found" });
  });

  app.patch("/api/v2/media-assets/:assetId/note", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = assetParams.safeParse(request.params);
    const body = noteBody.safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await upsertMediaNote(request.user, params.data.assetId, body.data.text, body.data.baseVersion);
    if (!result) return reply.code(404).send({ error: "not_found" });
    if (result.conflict) return reply.code(409).send({ error: "version_conflict", version: result.version });
    return { note: result.note };
  });

  app.get("/api/v2/media/on-this-day", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const query = onThisDayQuery.safeParse(request.query);
    if (!query.success || !validTimezone(query.data.timezone)) {
      return reply.code(400).send({ error: "invalid_request" });
    }
    const date = query.data.date ?? localDate(query.data.timezone);
    const parsedDate = new Date(`${date}T00:00:00Z`);
    if (Number.isNaN(parsedDate.getTime()) || parsedDate.toISOString().slice(0, 10) !== date) {
      return reply.code(400).send({ error: "invalid_request" });
    }
    const result = await onThisDay(request.user, { ...query.data, date });
    return result ?? reply.code(409).send({ error: "couple_required" });
  });
}
