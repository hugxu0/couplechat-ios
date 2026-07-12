import crypto from "node:crypto";
import { all, get, transaction, type PersonalItemRow } from "../db";
import type { AuthUser } from "../types";
import { activeIdentity, activeIdentityIn } from "../auth/identity";
import { appendSyncEvent } from "../sync/events";

export type PersonalItemKind = "reminder" | "memo";
export type PersonalItemScope = "personal" | "shared";

export interface PersonalItem {
  id: string;
  owner: string;
  kind: PersonalItemKind;
  scope: PersonalItemScope;
  title: string;
  bodyMarkdown: string;
  dueAt: number | null;
  isDone: boolean;
  createdAt: number;
  updatedAt: number;
  coupleId?: string;
  version: number;
}

export interface PersonalItemInput {
  kind: PersonalItemKind;
  scope?: PersonalItemScope;
  title: string;
  bodyMarkdown?: string;
  dueAt?: number | null;
  isDone?: boolean;
}

export interface PersonalItemPatch {
  title?: string;
  bodyMarkdown?: string;
  dueAt?: number | null;
  isDone?: boolean;
}

function toItem(row: PersonalItemRow): PersonalItem {
  return {
    id: row.id,
    owner: row.owner,
    kind: row.kind as PersonalItemKind,
    scope: (row.scope as PersonalItemScope) || "personal",
    title: row.title,
    bodyMarkdown: row.body_markdown,
    dueAt: row.due_at,
    isDone: row.is_done === 1,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    coupleId: row.couple_id ?? undefined,
    version: row.version ?? 0,
  };
}

function canAccess(row: PersonalItemRow, accountId: string, coupleId: string | null): boolean {
  return row.scope === "shared" ? Boolean(coupleId && row.couple_id === coupleId) : row.owner_account_id === accountId;
}

export async function listPersonalItems(
  user: AuthUser,
  kind?: PersonalItemKind,
  scope?: PersonalItemScope,
) {
  const identity = await activeIdentity(user);
  if (!identity) return [];
  const effectiveScope = scope || "personal";
  const ownerColumn = effectiveScope === "shared" ? "couple_id" : "owner_account_id";
  const ownerId = effectiveScope === "shared" ? identity.coupleId : identity.accountId;
  if (!ownerId) return [];
  const rows = await all<PersonalItemRow>(
    `SELECT * FROM personal_items
     WHERE ${ownerColumn} = ? AND scope = ? AND deleted_at IS NULL
       ${kind ? "AND kind = ?" : ""}
     ORDER BY kind ASC, COALESCE(due_at, updated_at) ASC, updated_at DESC`,
    kind ? [ownerId, effectiveScope, kind] : [ownerId, effectiveScope],
  );
  return rows.map(toItem);
}

export async function createPersonalItem(user: AuthUser, input: PersonalItemInput) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity) return null;
    const now = Date.now();
    const id = crypto.randomUUID();
    const scope = input.scope || "personal";
    if (scope === "shared" && !identity.coupleId) return null;
    await db.run(
      `INSERT INTO personal_items
       (id, owner, kind, scope, title, body_markdown, due_at, is_done, created_at, updated_at,
        owner_account_id, couple_id, created_by_account_id, version)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)`,
      [id, user.username, input.kind, scope, input.title, input.bodyMarkdown ?? "",
        input.dueAt ?? null, input.isDone ? 1 : 0, now, now,
        scope === "personal" ? identity.accountId : null,
        scope === "shared" ? identity.coupleId : null, identity.accountId],
    );
    const draft = await db.get<PersonalItemRow>("SELECT * FROM personal_items WHERE id = ?", [id]);
    if (!draft) return null;
    const eventVersion = await appendSyncEvent(db, {
      coupleId: scope === "shared" ? identity.coupleId : null,
      accountId: scope === "personal" ? identity.accountId : null,
      entityType: "personalItem",
      entityId: id,
      operation: "upsert",
      payload: toItem(draft),
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    await db.run("UPDATE personal_items SET version = ? WHERE id = ?", [eventVersion, id]);
    const created = await db.get<PersonalItemRow>("SELECT * FROM personal_items WHERE id = ?", [id]);
    return created ? toItem(created) : null;
  });
}

export async function getPersonalItem(user: AuthUser, id: string) {
  const identity = await activeIdentity(user);
  if (!identity) return null;
  const row = await get<PersonalItemRow>(
    "SELECT * FROM personal_items WHERE id = ? AND deleted_at IS NULL",
    [id],
  );
  return row && canAccess(row, identity.accountId, identity.coupleId) ? toItem(row) : null;
}

export async function updatePersonalItem(user: AuthUser, id: string, patch: PersonalItemPatch) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity) return null;
    const row = await db.get<PersonalItemRow>(
      "SELECT * FROM personal_items WHERE id = ? AND deleted_at IS NULL FOR UPDATE",
      [id],
    );
    if (!row || !canAccess(row, identity.accountId, identity.coupleId)) return null;
    const now = Date.now();
    await db.run(
      `UPDATE personal_items SET title = ?, body_markdown = ?, due_at = ?, is_done = ?, updated_at = ?
       WHERE id = ?`,
      [patch.title ?? row.title, patch.bodyMarkdown ?? row.body_markdown,
        Object.prototype.hasOwnProperty.call(patch, "dueAt") ? patch.dueAt ?? null : row.due_at,
        (patch.isDone ?? row.is_done === 1) ? 1 : 0, now, id],
    );
    const draft = await db.get<PersonalItemRow>("SELECT * FROM personal_items WHERE id = ?", [id]);
    if (!draft) return null;
    const eventVersion = await appendSyncEvent(db, {
      coupleId: row.scope === "shared" ? identity.coupleId : null,
      accountId: row.scope === "personal" ? identity.accountId : null,
      entityType: "personalItem",
      entityId: id,
      operation: "upsert",
      payload: toItem(draft),
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    await db.run("UPDATE personal_items SET version = ? WHERE id = ?", [eventVersion, id]);
    const updated = await db.get<PersonalItemRow>("SELECT * FROM personal_items WHERE id = ?", [id]);
    return updated ? toItem(updated) : null;
  });
}

export async function deletePersonalItem(user: AuthUser, id: string) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity) return false;
    const row = await db.get<PersonalItemRow>(
      "SELECT * FROM personal_items WHERE id = ? AND deleted_at IS NULL FOR UPDATE",
      [id],
    );
    if (!row || !canAccess(row, identity.accountId, identity.coupleId)) return false;
    const now = Date.now();
    await appendSyncEvent(db, {
      coupleId: row.scope === "shared" ? identity.coupleId : null,
      accountId: row.scope === "personal" ? identity.accountId : null,
      entityType: "personalItem",
      entityId: id,
      operation: "delete",
      payload: { id, kind: row.kind, scope: row.scope },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    await db.run("DELETE FROM personal_items WHERE id = ?", [id]);
    return true;
  });
}
