import { nanoid } from "nanoid";
import { transaction, type DatabaseTransaction } from "../db";
import { activeIdentityIn } from "../auth/identity";
import type { AuthUser } from "../types";
import { appendSyncEvent } from "../sync/events";

interface PetRow {
  id: string;
  couple_id: string;
  name: string;
  level: number;
  experience: number;
  satiety: number;
  cleanliness: number;
  mood: number;
  energy: number;
  timezone: string;
  version: number;
  state_updated_at: number;
  created_at: number;
  updated_at: number;
}

const interactionRules = {
  feed: {
    cooldownMs: 2 * 60 * 60_000,
    experience: 2,
    stats: { satiety: 25, cleanliness: 0, mood: 2, energy: 0 },
  },
  bathe: {
    cooldownMs: 12 * 60 * 60_000,
    experience: 3,
    stats: { satiety: 0, cleanliness: 45, mood: 3, energy: 0 },
  },
  play: {
    cooldownMs: 30 * 60_000,
    experience: 4,
    stats: { satiety: -5, cleanliness: 0, mood: 18, energy: -8 },
  },
  stroke: {
    cooldownMs: 30_000,
    experience: 1,
    stats: { satiety: 0, cleanliness: 0, mood: 6, energy: 0 },
  },
  sleep: {
    cooldownMs: 6 * 60 * 60_000,
    experience: 2,
    stats: { satiety: 0, cleanliness: 0, mood: 2, energy: 40 },
  },
} as const;

type PetInteractionKind = keyof typeof interactionRules;

// Old action rows can contain these two names. They are read-only aliases so existing
// cooldown/history data remains valid; new requests only accept the five current actions.
function canonicalInteractionKind(kind: string): PetInteractionKind | null {
  if (kind === "high_five") return "stroke";
  if (kind === "teaser") return "play";
  return kind in interactionRules ? kind as PetInteractionKind : null;
}

function clampStat(value: number): number {
  return Math.max(0, Math.min(100, value));
}

async function timezoneFor(db: DatabaseTransaction, user: AuthUser): Promise<string> {
  if (!user.deviceId) return "Asia/Shanghai";
  const device = await db.get<{ timezone: string }>("SELECT timezone FROM devices WHERE id = ?", [user.deviceId]);
  return device?.timezone || "Asia/Shanghai";
}

async function materializePetState(db: DatabaseTransaction, pet: PetRow, now: number): Promise<PetRow> {
  const hourMs = 60 * 60_000;
  const stateUpdatedAt = pet.state_updated_at > 0 ? pet.state_updated_at : pet.updated_at;
  const elapsedHours = Math.floor(Math.max(0, now - stateUpdatedAt) / hourMs);
  if (elapsedHours <= 0) return pet;
  const updated = {
    ...pet,
    satiety: clampStat(pet.satiety - (elapsedHours * 2)),
    cleanliness: clampStat(pet.cleanliness - elapsedHours),
    mood: clampStat(pet.mood - Math.floor(elapsedHours / 3)),
    energy: clampStat(pet.energy - elapsedHours),
    state_updated_at: stateUpdatedAt + (elapsedHours * hourMs),
  };
  await db.run(
    `UPDATE pets SET satiety = ?, cleanliness = ?, mood = ?, energy = ?, state_updated_at = ?
     WHERE id = ?`,
    [updated.satiety, updated.cleanliness, updated.mood, updated.energy, updated.state_updated_at, pet.id],
  );
  return updated;
}

async function ensurePet(
  db: DatabaseTransaction,
  coupleId: string,
  accountId: string,
  timezone: string,
  now: number,
): Promise<PetRow> {
  let pet = await db.get<PetRow>("SELECT * FROM pets WHERE couple_id = ? FOR UPDATE", [coupleId]);
  if (pet) return pet;
  const id = `pet_${nanoid(16)}`;
  await db.run(
    `INSERT INTO pets
     (id, couple_id, name, level, experience, satiety, cleanliness, mood, energy,
      coins, timezone, version, state_updated_at, created_at, updated_at)
     VALUES (?, ?, '大橘', 1, 0, 80, 80, 80, 100, 0, ?, 0, ?, ?, ?)
     ON CONFLICT(couple_id) DO NOTHING`,
    [id, coupleId, timezone, now, now, now],
  );
  pet = await db.get<PetRow>("SELECT * FROM pets WHERE couple_id = ? FOR UPDATE", [coupleId]);
  if (!pet) throw new Error("pet_create_failed");
  await appendSyncEvent(db, {
    coupleId,
    entityType: "pet",
    entityId: pet.id,
    operation: "upsert",
    payload: { id: pet.id, version: pet.version },
    actorAccountId: accountId,
    createdAt: now,
  });
  return pet;
}

async function petState(db: DatabaseTransaction, pet: PetRow) {
  const latest = await db.get<{ id: string; kind: string; display_name: string; created_at: number }>(
    `SELECT action.id, action.kind, account.display_name, action.created_at
     FROM pet_actions action JOIN accounts account ON account.id = action.account_id
     WHERE action.pet_id = ? ORDER BY action.created_at DESC, action.id DESC LIMIT 1`,
    [pet.id],
  );
  const recentActions = await db.all<{ kind: string; created_at: number }>(
    `SELECT kind, created_at FROM pet_actions WHERE pet_id = ?
     ORDER BY created_at DESC, id DESC LIMIT 100`,
    [pet.id],
  );
  const latestByKind = new Map<PetInteractionKind, number>();
  for (const action of recentActions) {
    const kind = canonicalInteractionKind(action.kind);
    if (kind && !latestByKind.has(kind)) latestByKind.set(kind, action.created_at);
  }
  const latestKind = latest ? canonicalInteractionKind(latest.kind) : null;
  return {
    id: pet.id,
    version: pet.version,
    level: pet.level,
    experience: pet.experience,
    satiety: pet.satiety,
    cleanliness: pet.cleanliness,
    mood: pet.mood,
    energy: pet.energy,
    latestInteraction: latest && latestKind ? {
      id: latest.id,
      kind: latestKind,
      actorName: latest.display_name,
      createdAt: latest.created_at,
    } : undefined,
    interactionCooldowns: [...latestByKind].map(([kind, createdAt]) => ({
      kind,
      availableAt: createdAt + interactionRules[kind].cooldownMs,
    })),
  };
}

async function loadPetContext(db: DatabaseTransaction, user: AuthUser, now = Date.now()) {
  const identity = await activeIdentityIn(db, user);
  if (!identity?.coupleId) return null;
  const ensuredPet = await ensurePet(
    db, identity.coupleId, identity.accountId, await timezoneFor(db, user), now);
  const pet = await materializePetState(db, ensuredPet, now);
  return { identity, pet };
}

export async function getPet(user: AuthUser) {
  return transaction(async (db) => {
    const context = await loadPetContext(db, user);
    return context ? { pet: await petState(db, context.pet) } : null;
  });
}

async function appendPetStateSync(
  db: DatabaseTransaction,
  user: AuthUser,
  context: NonNullable<Awaited<ReturnType<typeof loadPetContext>>>,
  now: number,
) {
  const current = await db.get<PetRow>("SELECT * FROM pets WHERE id = ?", [context.pet.id]);
  if (!current) throw new Error("pet_state_missing");
  const state = await petState(db, current);
  await appendSyncEvent(db, {
    coupleId: context.identity.coupleId,
    entityType: "pet",
    entityId: current.id,
    operation: "upsert",
    payload: state,
    actorAccountId: context.identity.accountId,
    actorDeviceId: user.deviceId,
    createdAt: now,
  });
  return { pet: state };
}

export async function interactPet(
  user: AuthUser,
  input: { kind: PetInteractionKind; idempotencyKey: string; baseVersion: number },
) {
  return transaction(async (db) => {
    const now = Date.now();
    const context = await loadPetContext(db, user, now);
    if (!context) return null;
    const kind = canonicalInteractionKind(input.kind);
    if (!kind) return null;
    const prior = await db.get<{ id: string; pet_id: string }>(
      "SELECT id, pet_id FROM pet_actions WHERE account_id = ? AND idempotency_key = ?",
      [context.identity.accountId, input.idempotencyKey],
    );
    if (prior) {
      if (prior.pet_id !== context.pet.id) return { idempotencyConflict: true as const };
      return { idempotencyConflict: false as const, conflict: false as const,
        pet: await petState(db, context.pet) };
    }
    if (context.pet.version !== input.baseVersion) {
      return { idempotencyConflict: false as const, conflict: true as const,
        pet: await petState(db, context.pet) };
    }
    const recentActions = await db.all<{ kind: string; created_at: number }>(
      `SELECT kind, created_at FROM pet_actions
       WHERE pet_id = ? ORDER BY created_at DESC, id DESC LIMIT 100`,
      [context.pet.id],
    );
    const latestSameKind = recentActions.find((action) => canonicalInteractionKind(action.kind) === kind);
    const availableAt = (latestSameKind?.created_at ?? 0) + interactionRules[kind].cooldownMs;
    if (availableAt > now) {
      return {
        idempotencyConflict: false as const,
        conflict: false as const,
        cooldown: true as const,
        availableAt,
        pet: await petState(db, context.pet),
      };
    }
    const rule = interactionRules[kind];
    const reward = { experience: rule.experience, ...rule.stats };
    await db.run(
      `INSERT INTO pet_actions (id, pet_id, account_id, kind, idempotency_key, reward_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [`petact_${nanoid(16)}`, context.pet.id, context.identity.accountId,
        kind, input.idempotencyKey, JSON.stringify(reward), now],
    );
    await db.run(
      `UPDATE pets SET experience = experience + ?,
       level = 1 + ((experience + ?) / 100),
       satiety = LEAST(100, GREATEST(0, satiety + ?)),
       cleanliness = LEAST(100, GREATEST(0, cleanliness + ?)),
       mood = LEAST(100, GREATEST(0, mood + ?)),
       energy = LEAST(100, GREATEST(0, energy + ?)),
       state_updated_at = ?, version = version + 1, updated_at = ? WHERE id = ?`,
      [reward.experience, reward.experience, reward.satiety, reward.cleanliness,
        reward.mood, reward.energy, now, now, context.pet.id],
    );
    return { idempotencyConflict: false as const, conflict: false as const,
      ...(await appendPetStateSync(db, user, context, now)) };
  });
}
