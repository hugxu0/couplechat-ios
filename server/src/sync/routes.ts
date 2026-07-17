import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { listPublicAccounts } from "../auth/accounts";
import { requireAuth } from "../auth/httpAuth";
import { countMessages, fetchMessageById, fetchMessages, getReadReceipts } from "../chat/messageService";
import { getSharedState } from "../shared/sharedService";
import { errorCodeFor, errorCodes } from "../errors/errorCodes";
import { startOperation } from "../observability/operationLog";

const channelSchema = z.enum(["couple", "ai"]);
const optionalTimestamp = z.coerce.number().finite().optional();
const messagesQuerySchema = z.object({
  channel: channelSchema,
  since: optionalTimestamp,
  after: optionalTimestamp,
  before: optionalTimestamp,
  around: optionalTimestamp,
  limit: z.coerce.number().int().min(1).max(300).default(80),
});
const messageParamsSchema = z.object({ id: z.string().min(1).max(128) });
const messageLookupQuerySchema = z.object({ channel: channelSchema });

/**
 * 首次登录/恢复会话只取有界快照。Socket 只承担此后的实时增量，
 * 不再在 connection 回调里同时推送多组初始化数据。
 */
export async function registerSyncRoutes(app: FastifyInstance) {
  app.get("/api/bootstrap", { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user;
    if (!user) return reply.code(401).send({ error: errorCodes.unauthorized });
    const operation = startOperation("sync.bootstrap", { requestId: request.id, channel: "all" });

    try {
      const [accounts, couple, ai, coupleRead, sharedState] = await Promise.all([
        listPublicAccounts(user),
        fetchMessages(user, { channel: "couple", limit: 40 }),
        fetchMessages(user, { channel: "ai", limit: 40 }),
        getReadReceipts(user, "couple"),
        getSharedState(user),
      ]);
      operation.success({ coupleCount: couple.length, aiCount: ai.length });

      return {
        ok: true,
        serverTime: Date.now(),
        accounts,
        messages: { couple, ai },
        readStates: { couple: coupleRead, ai: {} },
        sharedState,
      };
    } catch (error) {
      operation.failure(errorCodeFor(error));
      throw error;
    }
  });

  app.get("/api/messages", { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user;
    if (!user) return reply.code(401).send({ error: errorCodes.unauthorized });
    const parsed = messagesQuerySchema.safeParse(request.query);
    if (!parsed.success) return reply.code(400).send({ error: errorCodes.invalidRequest });
    const operation = startOperation("sync.messages", {
      requestId: request.id,
      channel: parsed.data.channel,
      direction: parsed.data.before !== undefined ? "before" : parsed.data.around !== undefined ? "around" : "latest",
    });
    try {
      const [list, total] = await Promise.all([
        fetchMessages(user, parsed.data),
        countMessages(user, parsed.data.channel),
      ]);
      operation.success({ resultCount: list.length, total });
      return { ok: true, list, total };
    } catch (error) {
      operation.failure(errorCodeFor(error));
      throw error;
    }
  });

  app.get("/api/messages/:id", { preHandler: requireAuth }, async (request, reply) => {
    const user = request.user;
    if (!user) return reply.code(401).send({ error: errorCodes.unauthorized });
    const params = messageParamsSchema.safeParse(request.params);
    const query = messageLookupQuerySchema.safeParse(request.query);
    if (!params.success || !query.success) {
      return reply.code(400).send({ error: errorCodes.invalidRequest });
    }
    const message = await fetchMessageById(user, query.data.channel, params.data.id);
    if (!message) return reply.code(404).send({ error: errorCodes.notFound });
    return { ok: true, message };
  });
}
