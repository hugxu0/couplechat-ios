import type { FastifyReply, FastifyRequest } from "fastify";
import { parseBearerToken, verifyActiveToken } from "./token";
import type { AuthUser } from "../types";

declare module "fastify" {
  interface FastifyRequest {
    user?: AuthUser;
  }
}

export async function requireAuth(request: FastifyRequest, reply: FastifyReply) {
  const token = parseBearerToken(request.headers.authorization);
  const user = token ? await verifyActiveToken(token) : null;
  if (!user) {
    await reply.code(401).send({ error: "unauthorized" });
    return;
  }
  request.user = user;
}
