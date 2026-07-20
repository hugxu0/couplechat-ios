import { randomInt } from "node:crypto";
import { nanoid } from "nanoid";
import { transaction, type DatabaseTransaction } from "../db";
import { activeIdentityIn } from "../auth/identity";
import type { AuthUser } from "../types";
import {
  cardCatalog,
  cardDefinition,
  randomCardFor,
  randomRarity,
  type CardDefinition,
  type CardRarity,
} from "./catalog";

const DAILY_DRAW_LIMIT = 3;
const DRAW_HIT_DENOMINATOR = 3;
const POSTPONE_MS = 24 * 60 * 60_000;

interface AccountRef {
  id: string;
  username: string;
  display_name: string;
}

interface InventoryRow {
  id: string;
  account_id: string;
  card_key: string;
  rarity: CardRarity;
  quantity: number;
  created_at: number;
  updated_at: number;
}

interface EffectRow {
  id: string;
  couple_id: string;
  sender_account_id: string;
  target_account_id: string;
  card_key: string;
  rarity: CardRarity;
  effect_kind: string;
  starts_at: number;
  expires_at: number | null;
  status: string;
  payload_json: string;
  idempotency_key: string;
  created_at: number;
  updated_at: number;
}

interface DrawRow {
  id: string;
  account_id: string;
  draw_day: string;
  idempotency_key: string;
  success: boolean;
  card_key: string | null;
  rarity: CardRarity | null;
  created_at: number;
}

export interface CardGameInventoryItem {
  id: string;
  cardKey: string;
  rarity: CardRarity;
  quantity: number;
}

export interface CardGameEffect {
  id: string;
  cardKey: string;
  title: string;
  rarity: CardRarity;
  summary: string;
  effectKind: string;
  senderUsername: string;
  senderName: string;
  targetUsername: string;
  targetName: string;
  startsAt: number;
  expiresAt: number | null;
  status: "active" | "pending" | "completed" | "expired";
  payload: Record<string, unknown>;
  createdAt: number;
}

export interface CardGameSnapshot {
  day: string;
  now: number;
  drawsUsed: number;
  drawsRemaining: number;
  inventory: CardGameInventoryItem[];
  partnerInventory: CardGameInventoryItem[];
  activeEffects: CardGameEffect[];
  recentEffects: CardGameEffect[];
  catalog: readonly CardDefinition[];
}

type FailureCode =
  | "couple_required"
  | "draw_limit_reached"
  | "card_not_found"
  | "card_not_owned"
  | "source_card_not_found"
  | "effect_required"
  | "effect_not_active"
  | "effect_not_owned"
  | "invalid_card_action";

interface Failure {
  ok: false;
  error: FailureCode;
}

interface Success<T> {
  ok: true;
  value: T;
}

type Result<T> = Failure | Success<T>;

export interface DrawResult {
  snapshot: CardGameSnapshot;
  draw: {
    success: boolean;
    card?: CardDefinition;
  };
}

export interface UseCardInput {
  cardKey: string;
  rarity: CardRarity;
  idempotencyKey: string;
  effectId?: string;
  sourceCardKey?: string;
  sourceRarity?: CardRarity;
}

export interface UseCardResult {
  snapshot: CardGameSnapshot;
  effect: CardGameEffect;
}

function dayKey(now: number): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(now));
  const values = new Map(parts.map((part) => [part.type, part.value]));
  return `${values.get("year")}-${values.get("month")}-${values.get("day")}`;
}

async function accountsInCouple(
  db: DatabaseTransaction,
  coupleId: string,
): Promise<AccountRef[]> {
  return db.all<AccountRef>(
    `SELECT account.id, account.username, account.display_name
       FROM couple_members member
       JOIN accounts account ON account.id = member.account_id
      WHERE member.couple_id = ? AND member.state = 'active'
      ORDER BY account.username ASC`,
    [coupleId],
  );
}

async function ensureDailyRow(
  db: DatabaseTransaction,
  accountId: string,
  today: string,
  now: number,
) {
  await db.run(
    `INSERT INTO card_game_daily_draws
       (account_id, draw_day, used_count, created_at, updated_at)
     VALUES (?, ?, 0, ?, ?)
     ON CONFLICT(account_id, draw_day) DO NOTHING`,
    [accountId, today, now, now],
  );
}

function parsePayload(raw: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(raw) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}

function currentEffectStatus(row: EffectRow, now: number): "active" | "pending" | "completed" | "expired" {
  if (row.status !== "active") return row.status === "expired" ? "expired" : "completed";
  if (row.expires_at !== null && row.expires_at <= now) return "expired";
  return row.starts_at > now ? "pending" : "active";
}

async function toEffect(
  row: EffectRow,
  accounts: Map<string, AccountRef>,
  now: number,
): Promise<CardGameEffect> {
  const definition = cardDefinition(row.card_key, row.rarity);
  const sender = accounts.get(row.sender_account_id);
  const target = accounts.get(row.target_account_id);
  return {
    id: row.id,
    cardKey: row.card_key,
    title: definition?.title ?? row.card_key,
    rarity: row.rarity,
    summary: definition?.summary ?? "卡片效果",
    effectKind: row.effect_kind,
    senderUsername: sender?.username ?? "",
    senderName: sender?.display_name ?? "对方",
    targetUsername: target?.username ?? "",
    targetName: target?.display_name ?? "对方",
    startsAt: row.starts_at,
    expiresAt: row.expires_at,
    status: currentEffectStatus(row, now),
    payload: parsePayload(row.payload_json),
    createdAt: row.created_at,
  };
}

async function inventoryFor(
  db: DatabaseTransaction,
  accountId: string,
): Promise<CardGameInventoryItem[]> {
  const rows = await db.all<InventoryRow>(
    `SELECT id, account_id, card_key, rarity, quantity, created_at, updated_at
       FROM card_game_inventory
      WHERE account_id = ? AND quantity > 0
      ORDER BY CASE rarity WHEN 'legendary' THEN 0 WHEN 'epic' THEN 1 WHEN 'rare' THEN 2 ELSE 3 END,
               updated_at DESC, id DESC`,
    [accountId],
  );
  return rows.map((row) => ({
    id: row.id,
    cardKey: row.card_key,
    rarity: row.rarity,
    quantity: row.quantity,
  }));
}

async function snapshotIn(
  db: DatabaseTransaction,
  accountId: string,
  coupleId: string,
  now: number,
): Promise<CardGameSnapshot> {
  const today = dayKey(now);
  await ensureDailyRow(db, accountId, today, now);
  const accounts = await accountsInCouple(db, coupleId);
  const partner = accounts.find((account) => account.id !== accountId);
  const draws = await db.get<{ used_count: number }>(
    "SELECT used_count FROM card_game_daily_draws WHERE account_id = ? AND draw_day = ?",
    [accountId, today],
  );
  const inventory = await inventoryFor(db, accountId);
  const partnerInventory = partner ? await inventoryFor(db, partner.id) : [];
  const rows = await db.all<EffectRow>(
    `SELECT * FROM card_game_effects
      WHERE couple_id = ?
      ORDER BY created_at DESC, id DESC
      LIMIT 100`,
    [coupleId],
  );
  const accountMap = new Map(accounts.map((account) => [account.id, account]));
  const effects = await Promise.all(rows.map((row) => toEffect(row, accountMap, now)));
  const activeEffects = effects.filter((effect) =>
    (effect.status === "active" || effect.status === "pending") && effect.expiresAt !== null,
  );
  return {
    day: today,
    now,
    drawsUsed: draws?.used_count ?? 0,
    drawsRemaining: Math.max(0, DAILY_DRAW_LIMIT - (draws?.used_count ?? 0)),
    inventory,
    partnerInventory,
    activeEffects,
    recentEffects: effects,
    catalog: cardCatalog,
  };
}

async function identityContext(db: DatabaseTransaction, user: AuthUser) {
  const identity = await activeIdentityIn(db, user);
  if (!identity?.coupleId) return null;
  const accounts = await accountsInCouple(db, identity.coupleId);
  const partner = accounts.find((account) => account.id !== identity.accountId);
  if (!partner) return null;
  return { identity, accounts, partner };
}

export async function getCardGame(user: AuthUser): Promise<Result<CardGameSnapshot>> {
  return transaction(async (db) => {
    const context = await identityContext(db, user);
    if (!context) return { ok: false, error: "couple_required" };
    return {
      ok: true,
      value: await snapshotIn(db, context.identity.accountId, context.identity.coupleId!, Date.now()),
    };
  });
}

export async function drawCard(
  user: AuthUser,
  idempotencyKey: string,
): Promise<Result<DrawResult>> {
  return transaction(async (db) => {
    const context = await identityContext(db, user);
    if (!context) return { ok: false, error: "couple_required" };
    await db.run(
      "SELECT pg_advisory_xact_lock(hashtext(?))",
      ["card-game:draw:" + context.identity.accountId + ":" + idempotencyKey],
    );
    const now = Date.now();
    const today = dayKey(now);
    const prior = await db.get<DrawRow>(
      `SELECT id, account_id, draw_day, idempotency_key, success, card_key, rarity, created_at
         FROM card_game_draws
        WHERE account_id = ? AND idempotency_key = ?`,
      [context.identity.accountId, idempotencyKey],
    );
    if (prior) {
      const card = prior.card_key && prior.rarity
        ? cardDefinition(prior.card_key, prior.rarity)
        : undefined;
      return {
        ok: true,
        value: {
          snapshot: await snapshotIn(db, context.identity.accountId, context.identity.coupleId!, now),
          draw: { success: prior.success, card },
        },
      };
    }
    await ensureDailyRow(db, context.identity.accountId, today, now);
    const daily = await db.get<{ used_count: number }>(
      `SELECT used_count FROM card_game_daily_draws
        WHERE account_id = ? AND draw_day = ? FOR UPDATE`,
      [context.identity.accountId, today],
    );
    if ((daily?.used_count ?? DAILY_DRAW_LIMIT) >= DAILY_DRAW_LIMIT) {
      return { ok: false, error: "draw_limit_reached" };
    }
    await db.run(
      `UPDATE card_game_daily_draws SET used_count = used_count + 1, updated_at = ?
        WHERE account_id = ? AND draw_day = ?`,
      [now, context.identity.accountId, today],
    );
    const success = randomInt(0, DRAW_HIT_DENOMINATOR) === 0;
    const card = success
      ? randomCardFor(randomRarity(randomInt(0, 1_000_000) / 1_000_000),
        randomInt(0, 1_000_000) / 1_000_000)
      : undefined;
    await db.run(
      `INSERT INTO card_game_draws
       (id, account_id, draw_day, idempotency_key, success, card_key, rarity, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [`carddraw_${nanoid(16)}`, context.identity.accountId, today, idempotencyKey,
        success, card?.key ?? null, card?.rarity ?? null, now],
    );
    if (card) {
      await db.run(
        `INSERT INTO card_game_inventory
         (id, account_id, card_key, rarity, quantity, created_at, updated_at)
         VALUES (?, ?, ?, ?, 1, ?, ?)
         ON CONFLICT(account_id, card_key, rarity)
         DO UPDATE SET quantity = card_game_inventory.quantity + 1, updated_at = EXCLUDED.updated_at`,
        [`cardinv_${nanoid(16)}`, context.identity.accountId, card.key, card.rarity, now, now],
      );
    }
    return {
      ok: true,
      value: {
        snapshot: await snapshotIn(db, context.identity.accountId, context.identity.coupleId!, now),
        draw: { success, card },
      },
    };
  });
}

async function consumeInventory(
  db: DatabaseTransaction,
  accountId: string,
  cardKey: string,
  rarity: CardRarity,
): Promise<Result<void>> {
  const row = await db.get<InventoryRow>(
    `SELECT * FROM card_game_inventory
      WHERE account_id = ? AND card_key = ? AND rarity = ? AND quantity > 0
      FOR UPDATE`,
    [accountId, cardKey, rarity],
  );
  if (!row) return { ok: false, error: "card_not_owned" };
  if (row.quantity <= 1) {
    await db.run("DELETE FROM card_game_inventory WHERE id = ?", [row.id]);
  } else {
    await db.run(
      "UPDATE card_game_inventory SET quantity = quantity - 1, updated_at = ? WHERE id = ?",
      [Date.now(), row.id],
    );
  }
  return { ok: true, value: undefined };
}

async function addInventory(
  db: DatabaseTransaction,
  accountId: string,
  cardKey: string,
  rarity: CardRarity,
  now: number,
) {
  await db.run(
    `INSERT INTO card_game_inventory
     (id, account_id, card_key, rarity, quantity, created_at, updated_at)
     VALUES (?, ?, ?, ?, 1, ?, ?)
     ON CONFLICT(account_id, card_key, rarity)
     DO UPDATE SET quantity = card_game_inventory.quantity + 1, updated_at = EXCLUDED.updated_at`,
    [`cardinv_${nanoid(16)}`, accountId, cardKey, rarity, now, now],
  );
}

async function effectById(
  db: DatabaseTransaction,
  effectId: string,
  coupleId: string,
): Promise<EffectRow | undefined> {
  return db.get<EffectRow>(
    "SELECT * FROM card_game_effects WHERE id = ? AND couple_id = ? FOR UPDATE",
    [effectId, coupleId],
  );
}

async function insertEffect(
  db: DatabaseTransaction,
  values: {
    coupleId: string;
    senderAccountId: string;
    targetAccountId: string;
    definition: CardDefinition;
    startsAt: number;
    expiresAt: number | null;
    status: "active" | "completed";
    payload?: Record<string, unknown>;
    idempotencyKey: string;
    now: number;
  },
): Promise<EffectRow> {
  const id = `cardfx_${nanoid(16)}`;
  await db.run(
    `INSERT INTO card_game_effects
     (id, couple_id, sender_account_id, target_account_id, card_key, rarity, effect_kind,
      starts_at, expires_at, status, payload_json, idempotency_key, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [id, values.coupleId, values.senderAccountId, values.targetAccountId,
      values.definition.key, values.definition.rarity, values.definition.effectKind,
      values.startsAt, values.expiresAt, values.status, JSON.stringify(values.payload ?? {}),
      values.idempotencyKey, values.now, values.now],
  );
  const row = await db.get<EffectRow>("SELECT * FROM card_game_effects WHERE id = ?", [id]);
  if (!row) throw new Error("card_game_effect_missing");
  return row;
}

export async function useCard(
  user: AuthUser,
  input: UseCardInput,
): Promise<Result<UseCardResult>> {
  return transaction(async (db) => {
    const context = await identityContext(db, user);
    if (!context) return { ok: false, error: "couple_required" };
    await db.run(
      "SELECT pg_advisory_xact_lock(hashtext(?))",
      ["card-game:use:" + context.identity.accountId + ":" + input.idempotencyKey],
    );
    const definition = cardDefinition(input.cardKey, input.rarity);
    if (!definition) return { ok: false, error: "card_not_found" };
    const prior = await db.get<EffectRow>(
      `SELECT * FROM card_game_effects
        WHERE sender_account_id = ? AND idempotency_key = ?`,
      [context.identity.accountId, input.idempotencyKey],
    );
    const now = Date.now();
    if (prior) {
      const accounts = new Map(context.accounts.map((account) => [account.id, account]));
      return {
        ok: true,
        value: {
          snapshot: await snapshotIn(db, context.identity.accountId, context.identity.coupleId!, now),
          effect: await toEffect(prior, accounts, now),
        },
      };
    }

    let createdEffect: EffectRow;

    if (definition.modifier === "copy") {
      if (!input.sourceCardKey || !input.sourceRarity) return { ok: false, error: "source_card_not_found" };
      const source = cardDefinition(input.sourceCardKey, input.sourceRarity);
      if (!source) return { ok: false, error: "source_card_not_found" };
      const sourceRow = await db.get<InventoryRow>(
        `SELECT * FROM card_game_inventory
          WHERE account_id = ? AND card_key = ? AND rarity = ? AND quantity > 0
          FOR UPDATE`,
        [context.partner.id, input.sourceCardKey, input.sourceRarity],
      );
      if (!sourceRow) return { ok: false, error: "source_card_not_found" };
      const consumed = await consumeInventory(db, context.identity.accountId, input.cardKey, input.rarity);
      if (!consumed.ok) return consumed;
      await addInventory(db, context.identity.accountId, source.key, source.rarity, now);
      createdEffect = await insertEffect(db, {
        coupleId: context.identity.coupleId!,
        senderAccountId: context.identity.accountId,
        targetAccountId: context.identity.accountId,
        definition,
        startsAt: now,
        expiresAt: null,
        status: "completed",
        payload: { copiedCardKey: source.key, copiedRarity: source.rarity },
        idempotencyKey: input.idempotencyKey,
        now,
      });
    } else if (definition.modifier === "addTime" || definition.modifier === "postpone" || definition.modifier === "qiankun") {
      if (!input.effectId) return { ok: false, error: "effect_required" };
      const target = await effectById(db, input.effectId, context.identity.coupleId!);
      if (!target) return { ok: false, error: "effect_not_active" };
      const targetStatus = currentEffectStatus(target, now);
      if (targetStatus !== "active" && targetStatus !== "pending") {
        return { ok: false, error: "effect_not_active" };
      }
      if (definition.modifier === "qiankun") {
        if (target.target_account_id !== context.identity.accountId) {
          return { ok: false, error: "effect_not_owned" };
        }
        const consumed = await consumeInventory(db, context.identity.accountId, input.cardKey, input.rarity);
        if (!consumed.ok) return consumed;
        await db.run(
          "UPDATE card_game_effects SET target_account_id = ?, updated_at = ? WHERE id = ?",
          [context.partner.id, now, target.id],
        );
        createdEffect = await insertEffect(db, {
          coupleId: context.identity.coupleId!,
          senderAccountId: context.identity.accountId,
          targetAccountId: context.partner.id,
          definition,
          startsAt: now,
          expiresAt: null,
          status: "completed",
          payload: { transferredEffectId: target.id },
          idempotencyKey: input.idempotencyKey,
          now,
        });
      } else {
        if (target.expires_at === null) return { ok: false, error: "effect_not_active" };
        const shift = definition.durationMs ?? POSTPONE_MS;
        const consumed = await consumeInventory(db, context.identity.accountId, input.cardKey, input.rarity);
        if (!consumed.ok) return consumed;
        const startsAt = definition.modifier === "postpone"
          ? target.starts_at + shift
          : target.starts_at;
        const expiresAt = target.expires_at + shift;
        await db.run(
          `UPDATE card_game_effects
              SET starts_at = ?, expires_at = ?, updated_at = ?
            WHERE id = ?`,
          [startsAt, expiresAt, now, target.id],
        );
        createdEffect = await insertEffect(db, {
          coupleId: context.identity.coupleId!,
          senderAccountId: context.identity.accountId,
          targetAccountId: target.target_account_id,
          definition,
          startsAt: now,
          expiresAt: null,
          status: "completed",
          payload: { modifiedEffectId: target.id, addedMs: shift },
          idempotencyKey: input.idempotencyKey,
          now,
        });
      }
    } else {
      const consumed = await consumeInventory(db, context.identity.accountId, input.cardKey, input.rarity);
      if (!consumed.ok) return consumed;
      const expiresAt = definition.durationMs ? now + definition.durationMs : null;
      createdEffect = await insertEffect(db, {
        coupleId: context.identity.coupleId!,
        senderAccountId: context.identity.accountId,
        targetAccountId: context.partner.id,
        definition,
        startsAt: now,
        expiresAt,
        status: expiresAt ? "active" : "completed",
        idempotencyKey: input.idempotencyKey,
        now,
      });
    }

    const accounts = new Map(context.accounts.map((account) => [account.id, account]));
    return {
      ok: true,
      value: {
        snapshot: await snapshotIn(db, context.identity.accountId, context.identity.coupleId!, now),
        effect: await toEffect(createdEffect, accounts, now),
      },
    };
  });
}
