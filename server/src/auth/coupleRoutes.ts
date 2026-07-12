import crypto from "node:crypto";
import type { FastifyInstance } from "fastify";
import { nanoid } from "nanoid";
import { z } from "zod";
import { get, transaction } from "../db";
import type { AuthUser } from "../types";
import { requireAuth } from "./httpAuth";
import { hashPassword } from "./password";
import { createDeviceSession } from "./devices";
import { createToken } from "./token";
import { activeIdentity, activeIdentityIn } from "./identity";

const deviceSchema = z.object({
  installationId: z.string().trim().min(8).max(160),
  platform: z.enum(["ios", "ipados"]),
  deviceName: z.string().trim().max(160).default(""),
  appVersion: z.string().trim().max(40).default(""),
  buildNumber: z.string().trim().max(40).default(""),
  locale: z.string().trim().max(40).default(""),
  timezone: z.string().trim().max(80).default(""),
});

const registerBody = z.object({
  username: z.string().trim().toLowerCase().regex(/^[a-z0-9_]{3,24}$/),
  displayName: z.string().trim().min(1).max(24),
  password: z.string().min(8).max(128),
  device: deviceSchema,
});
const coupleBody = z.object({ name: z.string().trim().max(40).default("") });
const joinBody = z.object({ code: z.string().trim().min(6).max(32) });

function inviteHash(code: string): string {
  return crypto.createHash("sha256").update(code.toUpperCase()).digest("hex");
}

function newInviteCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  return Array.from({ length: 8 }, () => alphabet[crypto.randomInt(alphabet.length)]).join("");
}

async function issueInvite(db: Parameters<Parameters<typeof transaction>[0]>[0], identity: {
  coupleId: string;
  memberId: string;
}) {
  const code = newInviteCode();
  const now = Date.now();
  await db.run(
    `UPDATE couple_invites SET revoked_at = ?
     WHERE couple_id = ? AND used_at IS NULL AND revoked_at IS NULL`,
    [now, identity.coupleId],
  );
  await db.run(
    `INSERT INTO couple_invites
     (id, couple_id, code_hash, created_by_member_id, expires_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [`inv_${nanoid(16)}`, identity.coupleId, inviteHash(code), identity.memberId,
      now + 7 * 24 * 60 * 60 * 1_000, now],
  );
  return { code, expiresAt: now + 7 * 24 * 60 * 60 * 1_000 };
}

export async function registerCoupleRoutes(app: FastifyInstance) {
  app.post("/api/v2/register", async (request, reply) => {
    const parsed = registerBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    if (await get("SELECT 1 AS found FROM accounts WHERE username = ?", [parsed.data.username])) {
      return reply.code(409).send({ error: "username_taken" });
    }
    const now = Date.now();
    const accountId = `acc_${nanoid(16)}`;
    const created = await transaction(async (db) => {
      const inserted = await db.run(
        `INSERT INTO accounts
         (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
         VALUES (?, ?, ?, ?, '', 'active', 0, ?, ?)
         ON CONFLICT(username) DO NOTHING`,
        [accountId, parsed.data.username, parsed.data.displayName,
          hashPassword(parsed.data.password), now, now],
      );
      if (!inserted) return false;
      await db.run(
        `INSERT INTO conversations (id, kind, owner_account_id, created_at)
         VALUES (?, 'ai', ?, ?)`,
        [`conv_ai_${nanoid(16)}`, accountId, now],
      );
      return true;
    });
    if (!created) return reply.code(409).send({ error: "username_taken" });
    let user: AuthUser = {
      username: parsed.data.username,
      name: parsed.data.displayName,
      accountId,
    };
    const sessionUser = await createDeviceSession(user, parsed.data.device);
    if (!sessionUser) return reply.code(500).send({ error: "session_create_failed" });
    user = sessionUser;
    return reply.code(201).send({
      token: createToken(user),
      username: user.username,
      name: user.name,
      deviceId: user.deviceId,
      paired: false,
    });
  });

  app.post("/api/v2/couples", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const parsed = coupleBody.safeParse(request.body ?? {});
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await transaction(async (db) => {
      await db.get("SELECT id FROM accounts WHERE username = ? FOR UPDATE", [request.user!.username]);
      const identity = await activeIdentityIn(db, request.user!);
      if (!identity || identity.coupleId) return null;
      const now = Date.now();
      const coupleId = `cpl_${nanoid(16)}`;
      const memberId = `mem_${nanoid(16)}`;
      await db.run(
        `INSERT INTO couples (id, name, status, created_by_account_id, created_at, updated_at, version)
         VALUES (?, ?, 'active', ?, ?, ?, 0)`,
        [coupleId, parsed.data.name, identity.accountId, now, now],
      );
      await db.run(
        `INSERT INTO couple_members (id, couple_id, account_id, role, state, joined_at, updated_at)
         VALUES (?, ?, ?, 'owner', 'active', ?, ?)`,
        [memberId, coupleId, identity.accountId, now, now],
      );
      await db.run(
        `INSERT INTO conversations (id, kind, couple_id, created_at)
         VALUES (?, 'couple', ?, ?)`,
        [`conv_couple_${nanoid(16)}`, coupleId, now],
      );
      return { coupleId, memberId, invite: await issueInvite(db, { coupleId, memberId }) };
    });
    if (!result) return reply.code(409).send({ error: "already_paired" });
    return reply.code(201).send({ ok: true, ...result });
  });

  app.post("/api/v2/couples/invites", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const result = await transaction(async (db) => {
      const identity = await activeIdentityIn(db, request.user!);
      if (!identity?.coupleId || !identity.memberId) return null;
      return issueInvite(db, { coupleId: identity.coupleId, memberId: identity.memberId });
    });
    if (!result) return reply.code(409).send({ error: "couple_required" });
    return { ok: true, invite: result };
  });

  app.post("/api/v2/couples/join", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const parsed = joinBody.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    const result = await transaction(async (db) => {
      await db.get("SELECT id FROM accounts WHERE username = ? FOR UPDATE", [request.user!.username]);
      const identity = await activeIdentityIn(db, request.user!);
      if (!identity || identity.coupleId) return { error: "already_paired" } as const;
      const now = Date.now();
      const invite = await db.get<{ id: string; couple_id: string }>(
        `SELECT invite.id, invite.couple_id FROM couple_invites invite
         JOIN couples couple ON couple.id = invite.couple_id AND couple.status = 'active'
         WHERE invite.code_hash = ? AND invite.used_at IS NULL AND invite.revoked_at IS NULL
           AND invite.expires_at > ? FOR UPDATE`,
        [inviteHash(parsed.data.code), now],
      );
      if (!invite) return { error: "invite_invalid" } as const;
      const count = await db.get<{ count: number }>(
        "SELECT COUNT(*) AS count FROM couple_members WHERE couple_id = ? AND state = 'active'",
        [invite.couple_id],
      );
      if (Number(count?.count ?? 0) >= 2) return { error: "couple_full" } as const;
      const memberId = `mem_${nanoid(16)}`;
      await db.run(
        `INSERT INTO couple_members (id, couple_id, account_id, role, state, joined_at, updated_at)
         VALUES (?, ?, ?, 'member', 'active', ?, ?)`,
        [memberId, invite.couple_id, identity.accountId, now, now],
      );
      await db.run(
        "UPDATE couple_invites SET used_at = ?, used_by_account_id = ? WHERE id = ?",
        [now, identity.accountId, invite.id],
      );
      return { coupleId: invite.couple_id, memberId };
    });
    if ("error" in result) return reply.code(409).send({ error: result.error });
    return { ok: true, ...result };
  });

  app.get("/api/v2/me/couple", { preHandler: requireAuth }, async (request, reply) => {
    if (!request.user) return reply.code(401).send({ error: "unauthorized" });
    const identity = await activeIdentity(request.user);
    if (!identity) return reply.code(401).send({ error: "unauthorized" });
    return { paired: Boolean(identity.coupleId), coupleId: identity.coupleId, memberId: identity.memberId };
  });
}
