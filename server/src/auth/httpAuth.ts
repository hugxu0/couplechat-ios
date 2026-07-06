import type { FastifyReply, FastifyRequest } from "fastify";
import { verifyToken } from "./token";
import type { AuthUser } from "../types";

declare module "fastify" {
  interface FastifyRequest {
    user?: AuthUser;
  }
}

export async function requireAuth(request: FastifyRequest, reply: FastifyReply) {
  const header = request.headers.authorization;
  const token = header?.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
  const user = token ? verifyToken(token) : null;
  if (!user) {
    await reply.code(401).send({ error: "unauthorized" });
    return;
  }
  request.user = user;
}
