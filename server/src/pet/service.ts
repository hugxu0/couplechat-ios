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
  mood: number;
  coins: number;
  timezone: string;
  version: number;
  created_at: number;
  updated_at: number;
}

interface PromptRow {
  id: string;
  local_date: string;
  prompt: string;
  response_type: "text";
  status: "open" | "settled";
  reward_json: string | null;
  settled_at: number | null;
}

const prompts = [
  "今天最想和对方分享的一件小事是什么？",
  "最近哪一个瞬间让你觉得‘我们真好’？",
  "如果今晚多出一小时，你想和对方怎么过？",
  "今天想认真夸对方哪一点？",
  "下一次约会，你最期待加入什么小惊喜？",
  "用三个词形容今天的你，也猜猜对方会写什么。",
  "最近共同完成的哪件小事最值得庆祝？",
];

function localDate(now: number, timezone: string): string {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(new Date(now));
    const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
    return `${value.year}-${value.month}-${value.day}`;
  } catch {
    return localDate(now, "Asia/Shanghai");
  }
}

function promptFor(date: string): string {
  let hash = 0;
  for (const character of date) hash = ((hash * 31) + character.charCodeAt(0)) >>> 0;
  return prompts[hash % prompts.length];
}

async function timezoneFor(db: DatabaseTransaction, user: AuthUser): Promise<string> {
  if (!user.deviceId) return "Asia/Shanghai";
  const device = await db.get<{ timezone: string }>("SELECT timezone FROM devices WHERE id = ?", [user.deviceId]);
  return device?.timezone || "Asia/Shanghai";
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
     (id, couple_id, name, level, experience, mood, coins, timezone, version, created_at, updated_at)
     VALUES (?, ?, '大橘', 1, 0, 80, 0, ?, 0, ?, ?)
     ON CONFLICT(couple_id) DO NOTHING`,
    [id, coupleId, timezone, now, now],
  );
  pet = await db.get<PetRow>("SELECT * FROM pets WHERE couple_id = ? FOR UPDATE", [coupleId]);
  if (!pet) throw new Error("pet_create_failed");
  const starterId = `petitem_${nanoid(16)}`;
  await db.run(
    `INSERT INTO pet_inventory
     (id, pet_id, item_key, name, kind, symbol_name, quantity, unlocked_at)
     VALUES (?, ?, 'starter_cushion', '暖橘软垫', 'furniture', 'sofa.fill', 1, ?)
     ON CONFLICT(pet_id, item_key) DO NOTHING`,
    [starterId, pet.id, now],
  );
  const starter = await db.get<{ id: string }>(
    "SELECT id FROM pet_inventory WHERE pet_id = ? AND item_key = 'starter_cushion'",
    [pet.id],
  );
  if (starter) {
    await db.run(
      `INSERT INTO pet_scene_items (pet_id, inventory_item_id, sort_order, placed_at)
       VALUES (?, ?, 0, ?) ON CONFLICT(pet_id, inventory_item_id) DO NOTHING`,
      [pet.id, starter.id, now],
    );
  }
  await appendSyncEvent(db, {
    coupleId,
    entityType: "pet",
    entityId: pet.id,
    operation: "upsert",
    payload: { id: pet.id, name: pet.name, version: pet.version },
    actorAccountId: accountId,
    createdAt: now,
  });
  return pet;
}

async function ensureToday(
  db: DatabaseTransaction,
  pet: PetRow,
  timezone: string,
  now: number,
): Promise<PromptRow> {
  const date = localDate(now, timezone);
  let prompt = await db.get<PromptRow>(
    "SELECT * FROM pet_prompt_instances WHERE pet_id = ? AND local_date = ? FOR UPDATE",
    [pet.id, date],
  );
  if (prompt) return prompt;
  const id = `petprompt_${nanoid(16)}`;
  await db.run(
    `INSERT INTO pet_prompt_instances
     (id, pet_id, local_date, prompt, response_type, status, created_at)
     VALUES (?, ?, ?, ?, 'text', 'open', ?)
     ON CONFLICT(pet_id, local_date) DO NOTHING`,
    [id, pet.id, date, promptFor(date), now],
  );
  prompt = await db.get<PromptRow>(
    "SELECT * FROM pet_prompt_instances WHERE pet_id = ? AND local_date = ? FOR UPDATE",
    [pet.id, date],
  );
  if (!prompt) throw new Error("pet_prompt_create_failed");
  return prompt;
}

async function petState(db: DatabaseTransaction, pet: PetRow, prompt: PromptRow | null) {
  const placed = await db.all<{ inventory_item_id: string }>(
    "SELECT inventory_item_id FROM pet_scene_items WHERE pet_id = ? ORDER BY sort_order, inventory_item_id",
    [pet.id],
  );
  const placedIds = placed.map((item) => item.inventory_item_id);
  const inventory = await db.all<{
    id: string; name: string; kind: string; symbol_name: string; unlocked_at: number; quantity: number;
  }>("SELECT id, name, kind, symbol_name, unlocked_at, quantity FROM pet_inventory WHERE pet_id = ? ORDER BY unlocked_at, id", [pet.id]);
  const responses = prompt ? await db.all<{
    username: string; display_name: string; text: string; responded_at: number;
  }>(
    `SELECT account.username, account.display_name, response.text, response.responded_at
     FROM pet_prompt_responses response JOIN accounts account ON account.id = response.account_id
     WHERE response.prompt_id = ? ORDER BY response.responded_at, response.id`,
    [prompt.id],
  ) : [];
  const moments = await db.all<{ id: string; title: string; detail: string; created_at: number }>(
    "SELECT id, title, detail, created_at FROM pet_moments WHERE pet_id = ? ORDER BY created_at DESC, id DESC LIMIT 20",
    [pet.id],
  );
  const latest = await db.get<{
    id: string; kind: string; display_name: string; created_at: number;
  }>(
    `SELECT action.id, action.kind, account.display_name, action.created_at
     FROM pet_actions action JOIN accounts account ON account.id = action.account_id
     WHERE action.pet_id = ? ORDER BY action.created_at DESC, action.id DESC LIMIT 1`,
    [pet.id],
  );
  return {
    id: pet.id,
    name: pet.name,
    version: pet.version,
    level: pet.level,
    experience: pet.experience,
    mood: pet.mood,
    coins: pet.coins,
    scene: {
      id: `scene_${pet.id}`,
      title: `${pet.name}的小窝`,
      placedItemIds: placedIds,
    },
    today: prompt ? {
      id: prompt.id,
      prompt: prompt.prompt,
      responseType: prompt.response_type,
      status: prompt.status,
      responses: responses.map((response) => ({
        username: response.username,
        displayName: response.display_name,
        text: response.text,
        respondedAt: response.responded_at,
      })),
      reward: prompt.reward_json ? JSON.parse(prompt.reward_json) : undefined,
    } : undefined,
    inventory: inventory.map((item) => ({
      id: item.id,
      name: item.name,
      kind: item.kind,
      symbolName: item.symbol_name || undefined,
      unlockedAt: item.unlocked_at,
      isPlaced: placedIds.includes(item.id),
      quantity: item.quantity,
    })),
    moments: moments.map((moment) => ({
      id: moment.id,
      title: moment.title,
      detail: moment.detail,
      createdAt: moment.created_at,
    })),
    latestInteraction: latest ? {
      id: latest.id,
      kind: latest.kind,
      actorName: latest.display_name,
      createdAt: latest.created_at,
    } : undefined,
  };
}

async function loadPetContext(db: DatabaseTransaction, user: AuthUser, now = Date.now()) {
  const identity = await activeIdentityIn(db, user);
  if (!identity?.coupleId) return null;
  const pet = await ensurePet(
    db, identity.coupleId, identity.accountId, await timezoneFor(db, user), now);
  const prompt = await ensureToday(db, pet, pet.timezone, now);
  return { identity, pet, prompt };
}

export async function getPet(user: AuthUser) {
  return transaction(async (db) => {
    const context = await loadPetContext(db, user);
    return context ? { pet: await petState(db, context.pet, context.prompt) } : null;
  });
}

async function appendPetStateSync(
  db: DatabaseTransaction,
  user: AuthUser,
  context: NonNullable<Awaited<ReturnType<typeof loadPetContext>>>,
  now: number,
) {
  const current = await db.get<PetRow>("SELECT * FROM pets WHERE id = ?", [context.pet.id]);
  const prompt = await db.get<PromptRow>("SELECT * FROM pet_prompt_instances WHERE id = ?", [context.prompt.id]);
  if (!current || !prompt) throw new Error("pet_state_missing");
  const state = await petState(db, current, prompt);
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

export async function respondToday(
  user: AuthUser,
  input: { promptId: string; text: string; idempotencyKey: string; baseVersion: number },
) {
  return transaction(async (db) => {
    const now = Date.now();
    const context = await loadPetContext(db, user, now);
    if (!context || context.prompt.id !== input.promptId) return null;
    const prior = await db.get<{ prompt_id: string }>(
      "SELECT prompt_id FROM pet_prompt_responses WHERE account_id = ? AND idempotency_key = ?",
      [context.identity.accountId, input.idempotencyKey],
    );
    if (prior) {
      if (prior.prompt_id !== context.prompt.id) return { idempotencyConflict: true as const };
      return { idempotencyConflict: false as const, conflict: false as const,
        pet: await petState(db, context.pet, context.prompt) };
    }
    if (context.pet.version !== input.baseVersion) {
      return { idempotencyConflict: false as const, conflict: true as const,
        pet: await petState(db, context.pet, context.prompt) };
    }
    const existing = await db.get(
      "SELECT 1 AS found FROM pet_prompt_responses WHERE prompt_id = ? AND account_id = ?",
      [context.prompt.id, context.identity.accountId],
    );
    if (existing) return { alreadyResponded: true as const };
    await db.run(
      `INSERT INTO pet_prompt_responses
       (id, prompt_id, account_id, text, idempotency_key, responded_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [`petresp_${nanoid(16)}`, context.prompt.id, context.identity.accountId,
        input.text, input.idempotencyKey, now],
    );
    const active = await db.get<{ count: number }>(
      "SELECT COUNT(*) AS count FROM couple_members WHERE couple_id = ? AND state = 'active'",
      [context.identity.coupleId],
    );
    const responseCount = await db.get<{ count: number }>(
      "SELECT COUNT(*) AS count FROM pet_prompt_responses WHERE prompt_id = ?",
      [context.prompt.id],
    );
    if (context.prompt.status === "open" && Number(active?.count ?? 0) >= 2 && Number(responseCount?.count ?? 0) >= 2) {
      const date = context.prompt.local_date;
      const itemId = `petitem_${nanoid(16)}`;
      const reward = {
        experience: 20,
        coins: 0,
        item: { id: itemId, name: `${date} 回忆星`, kind: "keepsake", symbolName: "star.fill" },
      };
      const settled = await db.run(
        `UPDATE pet_prompt_instances SET status = 'settled', reward_json = ?, settled_at = ?
         WHERE id = ? AND status = 'open'`,
        [JSON.stringify(reward), now, context.prompt.id],
      );
      if (settled) {
        await db.run(
          `INSERT INTO pet_inventory
           (id, pet_id, item_key, name, kind, symbol_name, quantity, unlocked_at)
           VALUES (?, ?, ?, ?, 'keepsake', 'star.fill', 1, ?)`,
          [itemId, context.pet.id, `memory_star_${date}`, `${date} 回忆星`, now],
        );
        await db.run(
          `UPDATE pets SET experience = experience + 20,
           level = 1 + ((experience + 20) / 100), mood = LEAST(100, mood + 5),
           version = version + 1, updated_at = ? WHERE id = ?`,
          [now, context.pet.id],
        );
        await db.run(
          `INSERT INTO pet_moments (id, pet_id, prompt_id, title, detail, created_at)
           VALUES (?, ?, ?, '今天，我们都回答了', ?, ?)`,
          [`petmoment_${nanoid(16)}`, context.pet.id, context.prompt.id,
            `两个人完成了「${context.prompt.prompt}」，大橘收藏了一颗回忆星。`, now],
        );
      }
    }
    return { idempotencyConflict: false as const, conflict: false as const,
      ...(await appendPetStateSync(db, user, context, now)) };
  });
}

export async function interactPet(
  user: AuthUser,
  input: { kind: "stroke" | "high_five" | "teaser"; idempotencyKey: string; baseVersion: number },
) {
  return transaction(async (db) => {
    const now = Date.now();
    const context = await loadPetContext(db, user, now);
    if (!context) return null;
    const prior = await db.get<{ id: string; pet_id: string }>(
      "SELECT id, pet_id FROM pet_actions WHERE account_id = ? AND idempotency_key = ?",
      [context.identity.accountId, input.idempotencyKey],
    );
    if (prior) {
      if (prior.pet_id !== context.pet.id) return { idempotencyConflict: true as const };
      return { idempotencyConflict: false as const, conflict: false as const,
        pet: await petState(db, context.pet, context.prompt) };
    }
    if (context.pet.version !== input.baseVersion) {
      return { idempotencyConflict: false as const, conflict: true as const,
        pet: await petState(db, context.pet, context.prompt) };
    }
    const reward = input.kind === "high_five" ? { experience: 3, mood: 2 }
      : input.kind === "teaser" ? { experience: 2, mood: 3 }
        : { experience: 1, mood: 2 };
    await db.run(
      `INSERT INTO pet_actions (id, pet_id, account_id, kind, idempotency_key, reward_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [`petact_${nanoid(16)}`, context.pet.id, context.identity.accountId,
        input.kind, input.idempotencyKey, JSON.stringify(reward), now],
    );
    await db.run(
      `UPDATE pets SET experience = experience + ?,
       level = 1 + ((experience + ?) / 100), mood = LEAST(100, mood + ?),
       version = version + 1, updated_at = ? WHERE id = ?`,
      [reward.experience, reward.experience, reward.mood, now, context.pet.id],
    );
    return { idempotencyConflict: false as const, conflict: false as const,
      ...(await appendPetStateSync(db, user, context, now)) };
  });
}

export async function renamePet(user: AuthUser, name: string, baseVersion: number) {
  return transaction(async (db) => {
    const now = Date.now();
    const context = await loadPetContext(db, user, now);
    if (!context) return null;
    if (context.pet.version !== baseVersion) {
      return { conflict: true as const, pet: await petState(db, context.pet, context.prompt) };
    }
    await db.run("UPDATE pets SET name = ?, version = version + 1, updated_at = ? WHERE id = ?", [name, now, context.pet.id]);
    return { conflict: false as const, ...(await appendPetStateSync(db, user, context, now)) };
  });
}

export async function updatePetScene(user: AuthUser, placedItemIds: string[], baseVersion: number) {
  return transaction(async (db) => {
    const now = Date.now();
    const context = await loadPetContext(db, user, now);
    if (!context) return null;
    if (context.pet.version !== baseVersion) {
      return { conflict: true as const, pet: await petState(db, context.pet, context.prompt) };
    }
    const unique = [...new Set(placedItemIds)];
    const owned = unique.length ? await db.all<{ id: string }>(
      `SELECT id FROM pet_inventory WHERE pet_id = ? AND id IN (${unique.map(() => "?").join(",")})`,
      [context.pet.id, ...unique],
    ) : [];
    if (owned.length !== unique.length) return { invalidItems: true as const };
    await db.run("DELETE FROM pet_scene_items WHERE pet_id = ?", [context.pet.id]);
    for (const [index, id] of unique.entries()) {
      await db.run(
        `INSERT INTO pet_scene_items (pet_id, inventory_item_id, sort_order, placed_at)
         VALUES (?, ?, ?, ?)`,
        [context.pet.id, id, index, now],
      );
    }
    await db.run("UPDATE pets SET version = version + 1, updated_at = ? WHERE id = ?", [now, context.pet.id]);
    return { conflict: false as const, invalidItems: false as const,
      ...(await appendPetStateSync(db, user, context, now)) };
  });
}
