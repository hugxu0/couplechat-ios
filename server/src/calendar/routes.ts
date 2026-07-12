import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "../auth/httpAuth";
import {
  completeCalendarEvent,
  createCalendarEvent,
  deleteCalendarEvent,
  listCalendarEvents,
  updateCalendarEvent,
} from "./service";
import { validEventRange, validTimezone } from "./time";

const idParams = z.object({ id: z.string().min(1).max(128) });
const listQuery = z.discriminatedUnion("view", [
  z.object({ view: z.literal("month"), month: z.string().regex(/^\d{4}-\d{2}$/),
    timezone: z.string().min(1).max(80), cursor: z.string().max(500).optional(),
    limit: z.coerce.number().int().min(1).max(500).default(500) }),
  z.object({ view: z.literal("agenda"), cursor: z.string().max(500).optional(),
    limit: z.coerce.number().int().min(1).max(100).default(30) }),
]);
const eventBody = z.object({
  scope: z.enum(["shared", "private"]),
  title: z.string().trim().min(1).max(120),
  notes: z.string().trim().max(5_000).default(""),
  startAt: z.number().int().nonnegative(),
  endAt: z.number().int().positive(),
  timezone: z.string().min(1).max(80),
  allDay: z.boolean().default(false),
});
const eventPatch = z.object({
  title: z.string().trim().min(1).max(120).optional(),
  notes: z.string().trim().max(5_000).optional(),
  startAt: z.number().int().nonnegative().optional(),
  endAt: z.number().int().positive().optional(),
  timezone: z.string().min(1).max(80).optional(),
  allDay: z.boolean().optional(),
  baseVersion: z.number().int().min(0),
}).refine((value) => Object.keys(value).some((key) => key !== "baseVersion"));
const completeBody = z.object({ completed: z.boolean().default(true), baseVersion: z.number().int().min(0) });
const versionBody = z.object({ baseVersion: z.number().int().min(0) });

export async function registerCalendarRoutes(app: FastifyInstance) {
  app.get("/api/v2/calendar/events", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const query = listQuery.safeParse(request.query);
    if (!query.success || (query.data.view === "month" && !validTimezone(query.data.timezone))) {
      return reply.code(400).send({ error: "invalid_request" });
    }
    const result = await listCalendarEvents(request.user, query.data);
    if (!result) return reply.code(401).send({ error: "unauthorized" });
    if (result.invalidRange) return reply.code(400).send({ error: "invalid_request" });
    return result;
  });

  app.post("/api/v2/calendar/events", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const body = eventBody.safeParse(request.body);
    if (!body.success || !validEventRange(body.data)) return reply.code(400).send({ error: "invalid_event_time" });
    const event = await createCalendarEvent(request.user, body.data);
    return event ? reply.code(201).send({ event }) : reply.code(409).send({ error: "couple_required" });
  });

  app.patch("/api/v2/calendar/events/:id", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    const body = eventPatch.safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await updateCalendarEvent(request.user, params.data.id, body.data);
    if (!result) return reply.code(404).send({ error: "not_found" });
    if ("invalidTime" in result && result.invalidTime) return reply.code(400).send({ error: "invalid_event_time" });
    if (result.conflict) return reply.code(409).send({ error: "version_conflict", event: result.event });
    return { event: result.event };
  });

  app.post("/api/v2/calendar/events/:id/complete", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    const body = completeBody.safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await completeCalendarEvent(request.user, params.data.id, body.data.completed, body.data.baseVersion);
    if (!result) return reply.code(404).send({ error: "not_found" });
    if (result.conflict) return reply.code(409).send({ error: "version_conflict", event: result.event });
    return { event: result.event };
  });

  app.delete("/api/v2/calendar/events/:id", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const params = idParams.safeParse(request.params);
    const body = versionBody.safeParse(request.body);
    if (!params.success || !body.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await deleteCalendarEvent(request.user, params.data.id, body.data.baseVersion);
    if (!result) return reply.code(404).send({ error: "not_found" });
    if (result.conflict) return reply.code(409).send({ error: "version_conflict", event: result.event });
    return { ok: true };
  });
}
