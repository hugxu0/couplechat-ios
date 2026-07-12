import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { authenticate, listPublicAccounts, setBarkKey } from "./accounts";
import { createToken } from "./token";
import { requireAuth } from "./httpAuth";
import { errorCodes } from "../errors/errorCodes";

const loginBody = z.object({
  username: z.string().min(1),
  password: z.string().min(1),
});

const barkBody = z.object({
  barkKey: z.string().trim().min(1).nullable(),
});

export async function registerAuthRoutes(app: FastifyInstance) {
  app.get("/api/accounts", async () => listPublicAccounts());

  app.post("/api/login", async (request, reply) => {
    const parsed = loginBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: errorCodes.invalidRequest });

    const user = await authenticate(parsed.data.username, parsed.data.password);
    if (!user) return reply.code(401).send({ error: errorCodes.invalidCredentials });

    return {
      token: createToken(user),
      username: user.username,
      name: user.name,
    };
  });

  // 客户端用来核实 token 是否仍有效（socket 报 unauthorized 时的二次确认）。
  app.get("/api/me", { preHandler: requireAuth }, async (request) => ({
    username: request.user!.username,
    name: request.user!.name,
  }));

  app.post("/api/me/push/bark", { preHandler: requireAuth }, async (request, reply) => {
    const parsed = barkBody.safeParse(request.body);
    if (!parsed.success || !request.user) return reply.code(400).send({ error: "invalid_request" });

    await setBarkKey(request.user.username, parsed.data.barkKey);
    return { ok: true };
  });
}
