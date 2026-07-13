import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { authenticate, listPublicAccounts } from "./accounts";
import { createToken } from "./token";
import { requireAuth } from "./httpAuth";
import { errorCodes } from "../errors/errorCodes";
import { createDeviceSession } from "./devices";
import { verifyActiveToken } from "./token";

const loginDeviceBody = z.object({
  installationId: z.string().trim().min(8).max(160),
  platform: z.enum(["ios", "ipados"]),
  deviceName: z.string().trim().max(160).default(""),
  appVersion: z.string().trim().max(40).default(""),
  buildNumber: z.string().trim().max(40).default(""),
  locale: z.string().trim().max(40).default(""),
  timezone: z.string().trim().max(80).default(""),
});

const loginBody = z.object({
  username: z.string().min(1),
  password: z.string().min(1),
  device: loginDeviceBody,
});

export async function registerAuthRoutes(app: FastifyInstance) {
  app.get("/api/accounts", async (request) => {
    const header = request.headers.authorization;
    const token = header?.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
    const user = token ? await verifyActiveToken(token) : undefined;
    return listPublicAccounts(user ?? undefined);
  });

  app.post("/api/v2/login", async (request, reply) => {
    const parsed = loginBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: errorCodes.invalidRequest });
    const authenticated = await authenticate(parsed.data.username, parsed.data.password);
    if (!authenticated) return reply.code(401).send({ error: errorCodes.invalidCredentials });
    const user = await createDeviceSession(authenticated, parsed.data.device);
    if (!user) return reply.code(401).send({ error: errorCodes.unauthorized });
    return {
      token: createToken(user),
      username: user.username,
      name: user.name,
      deviceId: user.deviceId,
    };
  });

  // 客户端用来核实 token 是否仍有效（socket 报 unauthorized 时的二次确认）。
  app.get("/api/me", { preHandler: requireAuth }, async (request) => ({
    username: request.user!.username,
    name: request.user!.name,
  }));

}
