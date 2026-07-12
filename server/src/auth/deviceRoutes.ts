import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAuth } from "./httpAuth";
import { listDevices, revokeDevice, saveCurrentDeviceBark } from "./devices";
import { disconnectDeviceSockets } from "../socket/realtime";

const currentDeviceBody = z.object({
  installationId: z.string().trim().min(8).max(160),
  platform: z.enum(["ios", "ipados"]),
  deviceName: z.string().trim().max(160).default(""),
  appVersion: z.string().trim().max(40).default(""),
  buildNumber: z.string().trim().max(40).default(""),
  locale: z.string().trim().max(40).default(""),
  timezone: z.string().trim().max(80).default(""),
  barkKey: z.string().trim().min(1).max(500).nullable(),
});

export async function registerDeviceRoutes(app: FastifyInstance) {
  app.get("/api/v2/me/devices", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    if (!request.user.deviceId) return reply.code(403).send({ error: "device_session_required" });
    return { ok: true, devices: await listDevices(request.user) };
  });

  app.put("/api/v2/me/devices/current/push/bark", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    if (!request.user.deviceId) return reply.code(403).send({ error: "device_session_required" });
    const parsed = currentDeviceBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    const device = await saveCurrentDeviceBark(request.user, parsed.data);
    if (!device) return reply.code(404).send({ error: "account_not_found" });
    return { ok: true, device };
  });

  app.delete<{ Params: { id: string } }>(
    "/api/v2/me/devices/:id",
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!request.user) return reply.code(401).send({ error: "unauthorized" });
      if (!await revokeDevice(request.user, request.params.id)) {
        return reply.code(404).send({ error: "device_not_found" });
      }
      disconnectDeviceSockets(request.params.id);
      return { ok: true };
    },
  );
}
