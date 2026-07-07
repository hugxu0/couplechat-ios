import crypto from "node:crypto";
import { all, get, run, type PersonalItemRow } from "../db";
import type { AuthUser } from "../types";

export type PersonalItemKind = "reminder" | "memo";

export interface PersonalItem {
  id: string;
  owner: string;
  kind: PersonalItemKind;
  title: string;
  bodyMarkdown: string;
  dueAt: number | null;
  isDone: boolean;
  createdAt: number;
  updatedAt: number;
}

export interface PersonalItemInput {
  kind: PersonalItemKind;
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
    title: row.title,
    bodyMarkdown: row.body_markdown,
    dueAt: row.due_at,
    isDone: row.is_done === 1,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export async function listPersonalItems(user: AuthUser, kind?: PersonalItemKind) {
  const rows = kind
    ? all<PersonalItemRow>(
        `SELECT * FROM personal_items
         WHERE owner = ? AND kind = ?
         ORDER BY COALESCE(due_at, updated_at) ASC, updated_at DESC`,
        [user.username, kind],
      )
    : all<PersonalItemRow>(
        `SELECT * FROM personal_items
         WHERE owner = ?
         ORDER BY kind ASC, COALESCE(due_at, updated_at) ASC, updated_at DESC`,
        [user.username],
      );
  return rows.map(toItem);
}

export async function createPersonalItem(user: AuthUser, input: PersonalItemInput) {
  const now = Date.now();
  const id = crypto.randomUUID();
  run(
    `INSERT INTO personal_items
      (id, owner, kind, title, body_markdown, due_at, is_done, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      id,
      user.username,
      input.kind,
      input.title,
      input.bodyMarkdown ?? "",
      input.dueAt ?? null,
      input.isDone ? 1 : 0,
      now,
      now,
    ],
  );
  return getPersonalItem(user, id);
}

export async function getPersonalItem(user: AuthUser, id: string) {
  const row = get<PersonalItemRow>(
    "SELECT * FROM personal_items WHERE owner = ? AND id = ?",
    [user.username, id],
  );
  return row ? toItem(row) : null;
}

export async function updatePersonalItem(user: AuthUser, id: string, patch: PersonalItemPatch) {
  const current = await getPersonalItem(user, id);
  if (!current) return null;

  const next = {
    title: patch.title ?? current.title,
    bodyMarkdown: patch.bodyMarkdown ?? current.bodyMarkdown,
    dueAt: Object.prototype.hasOwnProperty.call(patch, "dueAt") ? patch.dueAt ?? null : current.dueAt,
    isDone: patch.isDone ?? current.isDone,
  };

  run(
    `UPDATE personal_items
     SET title = ?, body_markdown = ?, due_at = ?, is_done = ?, updated_at = ?
     WHERE owner = ? AND id = ?`,
    [
      next.title,
      next.bodyMarkdown,
      next.dueAt,
      next.isDone ? 1 : 0,
      Date.now(),
      user.username,
      id,
    ],
  );
  return getPersonalItem(user, id);
}

export async function deletePersonalItem(user: AuthUser, id: string) {
  const current = await getPersonalItem(user, id);
  if (!current) return false;
  run("DELETE FROM personal_items WHERE owner = ? AND id = ?", [user.username, id]);
  return true;
}
