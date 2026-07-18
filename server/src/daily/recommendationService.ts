import { nanoid } from "nanoid";
import { all, get, transaction, type DatabaseTransaction } from "../db";
import { activeIdentity, activeIdentityIn } from "../auth/identity";
import type { AuthUser } from "../types";
import { appendSyncEvent } from "../sync/events";
import { decodeCursor, encodeCursor, isNumberStringCursor } from "../utils/cursor";
import { chat } from "../ai/provider";
import { GEN } from "../ai/settings";
import { addDays, cycleBounds, cycleDate } from "../ai/time";

type RecommendationSourceKind = "daju" | "member";
type RecommendationGenerationKind = "daily" | "refresh" | "manual";

interface RecommendationRow {
  id: string;
  couple_id: string;
  source_kind: RecommendationSourceKind;
  source_account_id: string | null;
  recipient_account_id: string | null;
  cycle_date: string;
  category: string | null;
  content: string;
  generation_kind: RecommendationGenerationKind;
  source_memory_ids_json: string;
  created_at: number;
  source_username?: string | null;
  source_name?: string | null;
  recipient_username?: string | null;
  read_at?: number | null;
}

interface RecommendationMemoryRow {
  id: string;
  layer: "event" | "state" | "plan" | "fact";
  content: string;
  importance: number;
  occurred_at: number | null;
  valid_from: number | null;
  updated_at: number;
}

export interface RecommendationItem {
  id: string;
  sourceKind: RecommendationSourceKind;
  sourceUsername?: string;
  sourceName: string;
  recipientUsername?: string;
  category?: string;
  content: string;
  cycleDate: string;
  generationKind: RecommendationGenerationKind;
  createdAt: number;
  isRead: boolean;
  isMine: boolean;
}

export interface RecommendationToday {
  cycleDate: string;
  daju: RecommendationItem;
  partner?: RecommendationItem;
  latestUnread?: RecommendationItem;
  unreadCount: number;
}

function cleanContent(value: string, maxLength = 500): string {
  return value
    .replace(/\r\n?/g, "\n")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
    .slice(0, maxLength);
}

function sourceIds(value: string): string[] {
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
}

function mapRecommendation(row: RecommendationRow, viewerAccountId: string): RecommendationItem {
  return {
    id: row.id,
    sourceKind: row.source_kind,
    sourceUsername: row.source_username ?? undefined,
    sourceName: row.source_kind === "daju" ? "大橘" : row.source_name ?? "TA",
    recipientUsername: row.recipient_username ?? undefined,
    category: row.category ?? undefined,
    content: row.content,
    cycleDate: row.cycle_date,
    generationKind: row.generation_kind,
    createdAt: row.created_at,
    isRead: row.recipient_account_id !== viewerAccountId || row.read_at != null,
    isMine: row.source_account_id === viewerAccountId,
  };
}

function recommendationSelect(viewerAccountId: string): { sql: string; params: string[] } {
  return {
    sql: `SELECT recommendation.*, source.username AS source_username,
                 source.display_name AS source_name,
                 recipient.username AS recipient_username,
                 viewer_state.read_at
            FROM recommendations recommendation
            LEFT JOIN accounts source ON source.id = recommendation.source_account_id
            LEFT JOIN accounts recipient ON recipient.id = recommendation.recipient_account_id
            LEFT JOIN recommendation_user_state viewer_state
              ON viewer_state.recommendation_id = recommendation.id
             AND viewer_state.account_id = ?`,
    params: [viewerAccountId],
  };
}

async function recommendationById(
  viewerAccountId: string,
  coupleId: string,
  recommendationId: string,
): Promise<RecommendationItem | null> {
  const select = recommendationSelect(viewerAccountId);
  const row = await get<RecommendationRow>(
    `${select.sql} WHERE recommendation.id = ? AND recommendation.couple_id = ?`,
    [...select.params, recommendationId, coupleId],
  );
  return row ? mapRecommendation(row, viewerAccountId) : null;
}

async function memberAccountIds(db: DatabaseTransaction, coupleId: string): Promise<string[]> {
  const rows = await db.all<{ account_id: string }>(
    `SELECT member.account_id
       FROM couple_members member
       JOIN accounts account ON account.id = member.account_id AND account.status = 'active'
      WHERE member.couple_id = ? AND member.state = 'active'
      ORDER BY member.joined_at ASC`,
    [coupleId],
  );
  return rows.map((row) => row.account_id);
}

async function insertRecommendation(
  user: AuthUser,
  input: {
    sourceKind: RecommendationSourceKind;
    sourceAccountId: string | null;
    recipientAccountId: string | null;
    generationKind: RecommendationGenerationKind;
    cycleDate: string;
    category?: string;
    content: string;
    sourceMemoryIds?: string[];
  },
): Promise<RecommendationItem | null> {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const coupleId = identity.coupleId;
  const id = `rec_${nanoid(16)}`;
  const now = Date.now();
  const insertedId = await transaction(async (db) => {
    const inserted = await db.run(
      `INSERT INTO recommendations
       (id, couple_id, source_kind, source_account_id, recipient_account_id,
        cycle_date, category, content, generation_kind, source_memory_ids_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ${input.sourceKind === "daju" && input.generationKind === "daily"
        ? "ON CONFLICT (couple_id, cycle_date) WHERE source_kind = 'daju' AND generation_kind = 'daily' DO NOTHING"
        : ""}`,
      [id, coupleId, input.sourceKind, input.sourceAccountId,
        input.recipientAccountId, input.cycleDate, input.category ?? null,
        input.content, input.generationKind,
        JSON.stringify(input.sourceMemoryIds ?? []), now],
    );
    if (inserted === 0) {
      const existing = await db.get<{ id: string }>(
        `SELECT id FROM recommendations
          WHERE couple_id = ? AND cycle_date = ?
            AND source_kind = 'daju' AND generation_kind = 'daily'
          ORDER BY created_at DESC, id DESC LIMIT 1`,
        [coupleId, input.cycleDate],
      );
      return existing?.id ?? null;
    }

    const accountIds = await memberAccountIds(db, coupleId);
    for (const accountId of accountIds) {
      const isRecipient = input.sourceKind === "member" && accountId === input.recipientAccountId;
      await db.run(
        `INSERT INTO recommendation_user_state
         (recommendation_id, account_id, read_at, hidden_at, created_at, updated_at)
         VALUES (?, ?, ?, NULL, ?, ?)`,
        [id, accountId, isRecipient ? null : now, now, now],
      );
    }
    await appendSyncEvent(db, {
      coupleId,
      entityType: "recommendation",
      entityId: id,
      operation: "upsert",
      payload: {
        id, cycleDate: input.cycleDate, sourceKind: input.sourceKind,
        category: input.category,
      },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return id;
  });
  return insertedId
    ? recommendationById(identity.accountId, coupleId, insertedId)
    : null;
}

async function recommendationMemories(
  coupleId: string,
  currentCycleDate: string,
): Promise<RecommendationMemoryRow[]> {
  const yesterday = cycleBounds(addDays(currentCycleDate, -1));
  const events = await all<RecommendationMemoryRow>(
    `SELECT id, layer, content, importance, occurred_at, valid_from, updated_at
       FROM ai_memory
      WHERE couple_id = ? AND scope = 'couple' AND status = 'active' AND layer = 'event'
        AND COALESCE(occurred_at, created_at) >= ?
        AND COALESCE(occurred_at, created_at) < ?
      ORDER BY importance DESC, COALESCE(occurred_at, created_at) DESC, id DESC LIMIT 8`,
    [coupleId, yesterday.start, yesterday.end],
  );
  const supporting = await all<RecommendationMemoryRow>(
    `SELECT id, layer, content, importance, occurred_at, valid_from, updated_at
       FROM ai_memory
      WHERE couple_id = ? AND scope = 'couple' AND status = 'active'
        AND layer IN ('state', 'plan', 'fact')
        AND (
          (layer = 'state' AND updated_at >= ?)
          OR (layer = 'plan' AND (valid_until IS NULL OR valid_until >= ?))
          OR layer = 'fact'
        )
      ORDER BY CASE layer WHEN 'state' THEN 0 WHEN 'plan' THEN 1 ELSE 2 END,
               importance DESC, updated_at DESC, id DESC LIMIT 10`,
    [coupleId, yesterday.start - 2 * 24 * 60 * 60 * 1_000, yesterday.start],
  );
  return [...events, ...supporting];
}

function recommendationPrompt(
  memories: RecommendationMemoryRow[],
  currentCycleDate: string,
  excluded: readonly GeneratedRecommendation[],
): string {
  const grouped = new Map<string, RecommendationMemoryRow[]>();
  for (const memory of memories) {
    const values = grouped.get(memory.layer) ?? [];
    values.push(memory);
    grouped.set(memory.layer, values);
  }
  const section = (layer: RecommendationMemoryRow["layer"], title: string) => {
    const values = grouped.get(layer) ?? [];
    return values.length
      ? `【${title}】\n${values.map((item) => `- ${item.content}`).join("\n")}`
      : `【${title}】\n- 无`;
  };
  const recent = excluded.slice(0, 8);
  return [
    `今天的作息日是 ${currentCycleDate}。`,
    section("event", "昨天的共同经历卡片（首要依据）"),
    section("state", "近期共同近况（只作补充）"),
    section("plan", "尚在进行的计划（只作补充）"),
    section("fact", "稳定偏好与事实（只作补充）"),
    recent.length
      ? `【最近已经推荐过，必须避开这些具体对象】\n${recent
        .map((item) => `- ${item.category}：${item.content}`)
        .join("\n")}`
      : "【最近已经推荐过】\n- 无",
  ].join("\n\n");
}

export interface GeneratedRecommendation {
  category: string;
  content: string;
}

const fallbackRecommendations: readonly GeneratedRecommendation[] = [
  { category: "电影", content: "一起看《海街日记》吧，四姐妹在镰仓生活的细碎日常，很适合两个人安静地看完。" },
  { category: "音乐", content: "一起听陈绮贞的《旅行的意义》吧，轻轻的吉他和夏夜很搭，听完可以交换最想重游的地方。" },
  { category: "阅读", content: "推荐《山茶文具店》，它写信也写人与人之间没说出口的心意，适合轮流读几页。" },
  { category: "美食", content: "今晚可以试试番茄肥牛锅，酸甜热乎又不复杂，配一份喜欢的主食就很满足。" },
  { category: "游戏", content: "推荐双人游戏《双人成行》，每一关都要互相配合，很适合两个人一起慢慢通关。" },
  { category: "纪录片", content: "一起看《地球脉动 II》吧，画面足够震撼，也很适合窝在一起边看边聊喜欢的动物。" },
  { category: "播客", content: "推荐播客《日谈公园》，挑一个你们都好奇的话题，从一段轻松聊天开始今晚的共同时间。" },
  { category: "旅行", content: "推荐苏州平江路作为一次慢旅行目的地，沿河走走、找间茶馆坐下，比匆忙赶景点更适合两个人。" },
  { category: "电视剧", content: "一起重温《请回答1988》吧，它不靠大起大落，却把家人、朋友和喜欢一个人的心情写得很暖。" },
  { category: "桌游", content: "推荐双人桌游《拼布艺术》，一局不长、规则也轻巧，很适合饭后坐下来慢慢拼一张被子。" },
] as const;

function normalizedRecommendationText(value: string): string {
  return value
    .toLocaleLowerCase("zh-CN")
    .replace(/[\s，。！？、；：,.!?;:'"“”‘’《》【】（）()\[\]{}·—-]/g, "");
}

function explicitRecommendationObject(content: string): string | null {
  const match = content.match(/[《“"「『]([^》”"」』]{2,40})[》”"」』]/);
  return match ? normalizedRecommendationText(match[1]) : null;
}

function bigramSimilarity(left: string, right: string): number {
  const pairs = (value: string) => {
    const characters = [...value];
    return new Set(characters.slice(0, -1).map((character, index) => character + characters[index + 1]));
  };
  const leftPairs = pairs(left);
  const rightPairs = pairs(right);
  if (leftPairs.size === 0 || rightPairs.size === 0) return left === right ? 1 : 0;
  let overlap = 0;
  for (const pair of leftPairs) if (rightPairs.has(pair)) overlap += 1;
  return (2 * overlap) / (leftPairs.size + rightPairs.size);
}

export function recommendationsAreSimilar(
  left: GeneratedRecommendation,
  right: GeneratedRecommendation,
): boolean {
  const leftObject = explicitRecommendationObject(left.content);
  const rightObject = explicitRecommendationObject(right.content);
  if (leftObject && rightObject && leftObject === rightObject) return true;
  const normalizedLeft = normalizedRecommendationText(`${left.category}${left.content}`);
  const normalizedRight = normalizedRecommendationText(`${right.category}${right.content}`);
  return normalizedLeft === normalizedRight || bigramSimilarity(normalizedLeft, normalizedRight) >= 0.64;
}

async function recentDajuRecommendations(
  coupleId: string,
  limit = 12,
): Promise<GeneratedRecommendation[]> {
  const rows = await all<{ category: string | null; content: string }>(
    `SELECT category, content FROM recommendations
      WHERE couple_id = ? AND source_kind = 'daju'
      ORDER BY created_at DESC, id DESC LIMIT ?`,
    [coupleId, limit],
  );
  return rows.map((row) => ({
    category: row.category?.trim() || "推荐",
    content: row.content,
  }));
}

export function parseGeneratedRecommendation(value: string | null): GeneratedRecommendation | null {
  if (!value) return null;
  const unfenced = value.trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
  const firstBrace = unfenced.indexOf("{");
  const lastBrace = unfenced.lastIndexOf("}");
  if (firstBrace < 0 || lastBrace <= firstBrace) return null;
  try {
    const parsed = JSON.parse(unfenced.slice(firstBrace, lastBrace + 1)) as {
      category?: unknown;
      content?: unknown;
    };
    if (typeof parsed.category !== "string" || typeof parsed.content !== "string") return null;
    const category = parsed.category
      .replace(/[\r\n\t【】\[\]#*]/g, "")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 12);
    const content = cleanContent(parsed.content, 240)
      .replace(/^[-–—•*#\s]+/, "")
      .replace(/^[“\"]|[”\"]$/g, "");
    if (!category || content.length < 8) return null;
    return { category, content };
  } catch {
    return null;
  }
}

export function fallbackRecommendation(
  currentCycleDate: string,
  excluded: readonly GeneratedRecommendation[] = [],
): GeneratedRecommendation {
  const seed = [...currentCycleDate].reduce((sum, character) => sum + character.charCodeAt(0), 0);
  const start = (seed + excluded.length) % fallbackRecommendations.length;
  for (let offset = 0; offset < fallbackRecommendations.length; offset += 1) {
    const candidate = fallbackRecommendations[(start + offset) % fallbackRecommendations.length];
    if (!excluded.some((item) => recommendationsAreSimilar(candidate, item))) return candidate;
  }
  return fallbackRecommendations[start];
}

async function generateRecommendation(
  memories: RecommendationMemoryRow[],
  currentCycleDate: string,
  excluded: readonly GeneratedRecommendation[],
): Promise<GeneratedRecommendation> {
  const rejected = [...excluded];
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const generated = await chat({
      profile: "task",
      scope: "recommendation",
      gen: GEN.dailyRecommendation,
      system: [
        "大橘给小旭小偲挑一个今天可一起体验的具体对象（作品/店/活动/美食等），禁止泛泛行动建议。",
        "优先参考昨日 event；state/plan/fact 仅作背景。勿用 relationship/insight，勿暴露记忆系统。",
        "勿编造不确定的上架/营业；避开输入中的近期推荐对象。",
        '只输出JSON：{"category":"2~8字","content":"30~110字含具体名称与一句理由"}',
      ].join("\n"),
      user: recommendationPrompt(memories, currentCycleDate, rejected),
    });
    if (!generated) break;
    const candidate = parseGeneratedRecommendation(generated);
    if (!candidate) continue;
    if (!rejected.some((item) => recommendationsAreSimilar(candidate, item))) return candidate;
    rejected.unshift(candidate);
  }
  return fallbackRecommendation(currentCycleDate, rejected);
}

async function createDajuRecommendation(
  user: AuthUser,
  generationKind: "daily" | "refresh",
): Promise<RecommendationItem | null> {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const date = cycleDate();
  const [memories, recent] = await Promise.all([
    recommendationMemories(identity.coupleId, date),
    recentDajuRecommendations(identity.coupleId),
  ]);
  const recommendation = await generateRecommendation(memories, date, recent);
  return insertRecommendation(user, {
    sourceKind: "daju",
    sourceAccountId: null,
    recipientAccountId: null,
    generationKind,
    cycleDate: date,
    category: recommendation.category,
    content: recommendation.content,
    sourceMemoryIds: memories.map((memory) => memory.id),
  });
}

async function upgradeLegacyDajuRecommendation(
  user: AuthUser,
  recommendationId: string,
): Promise<RecommendationItem | null> {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const date = cycleDate();
  const [memories, recent] = await Promise.all([
    recommendationMemories(identity.coupleId, date),
    recentDajuRecommendations(identity.coupleId),
  ]);
  const recommendation = await generateRecommendation(memories, date, recent);
  await transaction(async (db) => {
    const now = Date.now();
    const updated = await db.run(
      `UPDATE recommendations
          SET category = ?, content = ?, source_memory_ids_json = ?
        WHERE id = ? AND couple_id = ? AND source_kind = 'daju'
          AND (category IS NULL OR BTRIM(category) = '')`,
      [recommendation.category, recommendation.content,
        JSON.stringify(memories.map((memory) => memory.id)),
        recommendationId, identity.coupleId],
    );
    if (updated === 0) return;
    await appendSyncEvent(db, {
      coupleId: identity.coupleId,
      entityType: "recommendation",
      entityId: recommendationId,
      operation: "upsert",
      payload: { id: recommendationId, cycleDate: date, sourceKind: "daju", category: recommendation.category },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
  });
  return recommendationById(identity.accountId, identity.coupleId, recommendationId);
}

async function latestDajuRecommendation(
  viewerAccountId: string,
  coupleId: string,
  date: string,
): Promise<RecommendationItem | null> {
  const select = recommendationSelect(viewerAccountId);
  const row = await get<RecommendationRow>(
    `${select.sql}
      WHERE recommendation.couple_id = ? AND recommendation.cycle_date = ?
        AND recommendation.source_kind = 'daju'
      ORDER BY recommendation.created_at DESC, recommendation.id DESC LIMIT 1`,
    [...select.params, coupleId, date],
  );
  return row ? mapRecommendation(row, viewerAccountId) : null;
}

async function latestMemberRecommendation(
  viewerAccountId: string,
  coupleId: string,
  unreadOnly = false,
): Promise<RecommendationItem | null> {
  const select = recommendationSelect(viewerAccountId);
  const row = await get<RecommendationRow>(
    `${select.sql}
      WHERE recommendation.couple_id = ? AND recommendation.source_kind = 'member'
        AND recommendation.recipient_account_id = ?
        ${unreadOnly ? "AND viewer_state.read_at IS NULL AND viewer_state.hidden_at IS NULL" : ""}
      ORDER BY recommendation.created_at DESC, recommendation.id DESC LIMIT 1`,
    [...select.params, coupleId, viewerAccountId],
  );
  return row ? mapRecommendation(row, viewerAccountId) : null;
}

export async function ensureTodayRecommendation(
  user: AuthUser,
  prepareMemories?: () => Promise<void>,
): Promise<RecommendationItem | null> {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const date = cycleDate();
  const existing = await latestDajuRecommendation(identity.accountId, identity.coupleId, date);
  if (existing?.category) return existing;
  if (existing) return upgradeLegacyDajuRecommendation(user, existing.id);
  if (prepareMemories) {
    await prepareMemories();
    const afterPreparation = await latestDajuRecommendation(identity.accountId, identity.coupleId, date);
    if (afterPreparation?.category) return afterPreparation;
    if (afterPreparation) return upgradeLegacyDajuRecommendation(user, afterPreparation.id);
  }
  return createDajuRecommendation(user, "daily");
}

export async function refreshTodayRecommendation(user: AuthUser): Promise<RecommendationItem | null> {
  return createDajuRecommendation(user, "refresh");
}

export async function createMemberRecommendation(
  user: AuthUser,
  rawContent: string,
): Promise<RecommendationItem | null> {
  const content = cleanContent(rawContent);
  if (!content) return null;
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const partner = await get<{ account_id: string }>(
    `SELECT member.account_id
       FROM couple_members member
       JOIN accounts account ON account.id = member.account_id AND account.status = 'active'
      WHERE member.couple_id = ? AND member.state = 'active' AND member.account_id <> ?
      ORDER BY member.joined_at ASC LIMIT 1`,
    [identity.coupleId, identity.accountId],
  );
  if (!partner) return null;
  return insertRecommendation(user, {
    sourceKind: "member",
    sourceAccountId: identity.accountId,
    recipientAccountId: partner.account_id,
    generationKind: "manual",
    cycleDate: cycleDate(),
    content,
  });
}

export async function unreadRecommendationCount(user: AuthUser): Promise<number> {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return 0;
  const row = await get<{ count: number }>(
    `SELECT COUNT(*) AS count
       FROM recommendations recommendation
       JOIN recommendation_user_state state
         ON state.recommendation_id = recommendation.id AND state.account_id = ?
      WHERE recommendation.couple_id = ? AND recommendation.source_kind = 'member'
        AND recommendation.recipient_account_id = ?
        AND state.read_at IS NULL AND state.hidden_at IS NULL`,
    [identity.accountId, identity.coupleId, identity.accountId],
  );
  return Number(row?.count ?? 0);
}

export async function todayRecommendations(user: AuthUser): Promise<RecommendationToday | null> {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const daju = await ensureTodayRecommendation(user);
  if (!daju) return null;
  const [partner, latestUnread, unreadCount] = await Promise.all([
    latestMemberRecommendation(identity.accountId, identity.coupleId),
    latestMemberRecommendation(identity.accountId, identity.coupleId, true),
    unreadRecommendationCount(user),
  ]);
  return {
    cycleDate: cycleDate(),
    daju,
    partner: partner ?? undefined,
    latestUnread: latestUnread ?? undefined,
    unreadCount,
  };
}

export async function readThroughRecommendation(
  user: AuthUser,
  recommendationId: string,
): Promise<boolean> {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) return false;
    const target = await db.get<{ created_at: number }>(
      `SELECT created_at FROM recommendations
        WHERE id = ? AND couple_id = ? AND source_kind = 'member'
          AND recipient_account_id = ?`,
      [recommendationId, identity.coupleId, identity.accountId],
    );
    if (!target) return false;
    const now = Date.now();
    await db.run(
      `UPDATE recommendation_user_state state
          SET read_at = COALESCE(read_at, ?), updated_at = ?
         FROM recommendations recommendation
        WHERE state.recommendation_id = recommendation.id
          AND state.account_id = ? AND state.read_at IS NULL
          AND recommendation.couple_id = ? AND recommendation.source_kind = 'member'
          AND recommendation.recipient_account_id = ?
          AND recommendation.created_at <= ?`,
      [now, now, identity.accountId, identity.coupleId, identity.accountId, target.created_at],
    );
    await appendSyncEvent(db, {
      accountId: identity.accountId,
      entityType: "recommendation_state",
      entityId: recommendationId,
      operation: "upsert",
      payload: { id: recommendationId, readThrough: target.created_at },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return true;
  });
}

export async function hideRecommendation(
  user: AuthUser,
  recommendationId: string,
): Promise<boolean> {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity?.coupleId) return false;
    const state = await db.get<{ found: number }>(
      `SELECT 1 AS found
         FROM recommendation_user_state state
         JOIN recommendations recommendation ON recommendation.id = state.recommendation_id
        WHERE state.recommendation_id = ? AND state.account_id = ?
          AND recommendation.couple_id = ?`,
      [recommendationId, identity.accountId, identity.coupleId],
    );
    if (!state) return false;
    const now = Date.now();
    await db.run(
      `UPDATE recommendation_user_state
          SET hidden_at = ?, read_at = COALESCE(read_at, ?), updated_at = ?
        WHERE recommendation_id = ? AND account_id = ?`,
      [now, now, now, recommendationId, identity.accountId],
    );
    await appendSyncEvent(db, {
      accountId: identity.accountId,
      entityType: "recommendation_state",
      entityId: recommendationId,
      operation: "delete",
      payload: { id: recommendationId },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return true;
  });
}

export async function recommendationHistory(
  user: AuthUser,
  cursor?: string,
  limit = 30,
): Promise<{ recommendations: RecommendationItem[]; nextCursor?: string; hasMore: boolean } | null> {
  const identity = await activeIdentity(user);
  if (!identity?.coupleId) return null;
  const decoded = decodeCursor(cursor, isNumberStringCursor);
  const select = recommendationSelect(identity.accountId);
  const rows = await all<RecommendationRow>(
    `${select.sql}
      JOIN recommendation_user_state history_state
        ON history_state.recommendation_id = recommendation.id
       AND history_state.account_id = ? AND history_state.hidden_at IS NULL
      WHERE recommendation.couple_id = ?
        AND (?::BIGINT IS NULL OR (recommendation.created_at, recommendation.id) < (?, ?))
      ORDER BY recommendation.created_at DESC, recommendation.id DESC LIMIT ?`,
    [...select.params, identity.accountId, identity.coupleId,
      decoded?.[0] ?? null, decoded?.[0] ?? 0, decoded?.[1] ?? "", limit + 1],
  );
  const page = rows.slice(0, limit);
  return {
    recommendations: page.map((row) => mapRecommendation(row, identity.accountId)),
    nextCursor: rows.length > limit && page.length
      ? encodeCursor([page.at(-1)!.created_at, page.at(-1)!.id]) : undefined,
    hasMore: rows.length > limit,
  };
}

export async function recommendationMemoryIds(recommendationId: string): Promise<string[]> {
  const row = await get<{ source_memory_ids_json: string }>(
    "SELECT source_memory_ids_json FROM recommendations WHERE id = ?",
    [recommendationId],
  );
  return row ? sourceIds(row.source_memory_ids_json) : [];
}
