import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { authenticate, listPublicAccounts } from "./accounts";
import { createToken } from "./token";
import { requireAuth } from "./httpAuth";
import { errorCodes } from "../errors/errorCodes";
import { createDeviceSession } from "./devices";
import { verifyActiveToken } from "./token";
import { MAX_PASSWORD_LENGTH } from "./password";
import { consumeRateLimit } from "./rateLimit";

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
  username: z.string().min(1).max(64),
  password: z.string().min(1).max(MAX_PASSWORD_LENGTH),
  device: loginDeviceBody,
});

function clientIp(request: { ip: string; headers: Record<string, unknown> }): string {
  const forwarded = request.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.trim()) {
    return forwarded.split(",")[0]?.trim() || request.ip;
  }
  return request.ip.replace(/^::ffff:/, "");
}

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

    const ip = clientIp(request);
    const usernameKey = parsed.data.username.trim().toLowerCase();
    // 每 IP 每分钟 20 次；每用户名每分钟 10 次。失败与成功都计入，防扫库。
    const ipLimit = consumeRateLimit({ key: `login:ip:${ip}`, limit: 20, windowMs: 60_000 });
    const userLimit = consumeRateLimit({ key: `login:user:${usernameKey}`, limit: 10, windowMs: 60_000 });
    if (!ipLimit.allowed || !userLimit.allowed) {
      const retryAfterMs = Math.max(ipLimit.retryAfterMs, userLimit.retryAfterMs);
      reply.header("Retry-After", String(Math.ceil(retryAfterMs / 1000) || 1));
      return reply.code(429).send({ error: errorCodes.rateLimited });
    }

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
