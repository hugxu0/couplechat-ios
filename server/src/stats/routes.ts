import type { FastifyInstance } from "fastify";
import { requireAuth } from "../auth/httpAuth";
import { all } from "../db";
import { conversationIdentity } from "../auth/identity";
import { errorCodes } from "../errors/errorCodes";

interface CountRow {
  bucket: string;
  sender: string;
  count: number;
}

interface StatsSnapshot {
  days: CountRow[];
  months: CountRow[];
}

interface CachedStats {
  expiresAt: number;
  value: StatsSnapshot;
}

const STATS_CACHE_TTL_MS = 60_000;
const STATS_CACHE_MAX_ENTRIES = 16;
const statsCache = new Map<string, CachedStats>();
const statsLoads = new Map<string, Promise<StatsSnapshot>>();

async function loadStats(conversationId: string): Promise<StatsSnapshot> {
  const now = Date.now();
  const cached = statsCache.get(conversationId);
  if (cached && cached.expiresAt > now) return cached.value;

  const activeLoad = statsLoads.get(conversationId);
  if (activeLoad) return activeLoad;

  const load = (async () => {
    const days = await all<CountRow>(
      `SELECT to_char(to_timestamp(ts / 1000.0) AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD') AS bucket,
              sender, COUNT(*)::int AS count
       FROM messages
       WHERE conversation_id = ? AND kind = 'user' AND sender <> 'ai'
         AND ts >= ?
       GROUP BY bucket, sender
       ORDER BY bucket ASC`,
      [conversationId, Date.now() - 35 * 24 * 60 * 60 * 1000],
    );
    const months = await all<CountRow>(
      `SELECT to_char(to_timestamp(ts / 1000.0) AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM') AS bucket,
              sender, COUNT(*)::int AS count
       FROM messages
       WHERE conversation_id = ? AND kind = 'user' AND sender <> 'ai'
       GROUP BY bucket, sender
       ORDER BY bucket ASC`,
      [conversationId],
    );
    const value = { days, months };
    if (statsCache.size >= STATS_CACHE_MAX_ENTRIES && !statsCache.has(conversationId)) {
      statsCache.delete(statsCache.keys().next().value!);
    }
    statsCache.set(conversationId, { expiresAt: Date.now() + STATS_CACHE_TTL_MS, value });
    return value;
  })();

  statsLoads.set(conversationId, load);
  try {
    return await load;
  } finally {
    if (statsLoads.get(conversationId) === load) statsLoads.delete(conversationId);
  }
}

export async function registerStatsRoutes(app: FastifyInstance) {
  app.get("/api/v2/chat/stats", { preHandler: requireAuth }, async (request, reply) => {
    const identity = request.user
      ? await conversationIdentity(request.user, "couple")
      : null;
    if (!identity) {
      return reply.code(403).send({ error: errorCodes.unauthorized });
    }
    reply.header("Cache-Control", "private, max-age=30");
    return loadStats(identity.conversationId);
  });
}
