import { nanoid } from "nanoid";
import { all, transaction, type DatabaseTransaction } from "../db";
import { activeIdentity, activeIdentityIn } from "../auth/identity";
import type { AuthUser } from "../types";
import { appendSyncEvent } from "../sync/events";
import { monthRange, validEventRange } from "./time";

interface CalendarEventRow {
  id: string;
  scope: "shared" | "private";
  title: string;
  notes: string;
  start_at: number;
  end_at: number;
  timezone: string;
  all_day: boolean;
  status: "scheduled" | "completed";
  completed_at: number | null;
  created_at: number;
  updated_at: number;
  version: number;
  participants: unknown;
}

const eventProjection = `event.*,
  COALESCE((SELECT json_agg(json_build_object(
    'accountId', account.id, 'username', account.username, 'displayName', account.display_name,
    'status', participant.participation_status) ORDER BY account.username)
    FROM calendar_event_participants participant
    JOIN accounts account ON account.id = participant.account_id
    WHERE participant.event_id = event.id), '[]'::json) AS participants`;

function mapEvent(row: CalendarEventRow) {
  const participants = typeof row.participants === "string" ? JSON.parse(row.participants) : row.participants;
  return {
    id: row.id,
    scope: row.scope,
    title: row.title,
    notes: row.notes,
    startAt: row.start_at,
    endAt: row.end_at,
    timezone: row.timezone,
    allDay: row.all_day,
    status: row.status,
    completedAt: row.completed_at ?? undefined,
    participants,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    version: row.version,
  };
}

function encodeCursor(startAt: number, id: string): string {
  return Buffer.from(JSON.stringify([startAt, id])).toString("base64url");
}

function decodeCursor(cursor?: string): [number, string] | null {
  if (!cursor) return null;
  try {
    const value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    return Array.isArray(value) && typeof value[0] === "number" && typeof value[1] === "string"
      ? [value[0], value[1]] : null;
  } catch { return null; }
}

function visibleWhere() {
  return `((event.scope = 'shared' AND event.couple_id = ?)
    OR (event.scope = 'private' AND event.owner_account_id = ?))`;
}

async function visibleEvent(
  db: Pick<DatabaseTransaction, "get">,
  identity: { coupleId: string | null; accountId: string },
  id: string,
  lock = false,
) {
  return db.get<CalendarEventRow>(
    `SELECT ${eventProjection} FROM calendar_events event
     WHERE event.id = ? AND ${visibleWhere()}${lock ? " FOR UPDATE OF event" : ""}`,
    [id, identity.coupleId ?? "", identity.accountId],
  );
}

export async function listCalendarEvents(
  user: AuthUser,
  input: { view: "month"; month: string; timezone: string; cursor?: string; limit: number }
    | { view: "agenda"; cursor?: string; limit: number },
) {
  const identity = await activeIdentity(user);
  if (!identity) return null;
  if (input.view === "month") {
    const range = monthRange(input.month, input.timezone);
    if (!range) return { invalidRange: true as const };
    const cursor = decodeCursor(input.cursor);
    const rows = await all<CalendarEventRow>(
      `SELECT ${eventProjection} FROM calendar_events event
       WHERE ${visibleWhere()} AND event.start_at < ? AND event.end_at > ?
         AND (?::BIGINT IS NULL OR (event.start_at, event.id) > (?, ?))
       ORDER BY event.start_at ASC, event.id ASC LIMIT ?`,
      [identity.coupleId ?? "", identity.accountId, range.end, range.start,
        cursor?.[0] ?? null, cursor?.[0] ?? 0, cursor?.[1] ?? "", input.limit + 1],
    );
    const page = rows.slice(0, input.limit);
    return {
      invalidRange: false as const,
      events: page.map(mapEvent),
      nextCursor: rows.length > input.limit && page.length
        ? encodeCursor(page.at(-1)!.start_at, page.at(-1)!.id) : undefined,
      hasMore: rows.length > input.limit,
    };
  }
  const cursor = decodeCursor(input.cursor);
  const rows = await all<CalendarEventRow>(
    `SELECT ${eventProjection} FROM calendar_events event
     WHERE ${visibleWhere()}
       AND (?::BIGINT IS NULL OR (event.start_at, event.id) > (?, ?))
     ORDER BY event.start_at ASC, event.id ASC LIMIT ?`,
    [identity.coupleId ?? "", identity.accountId,
      cursor?.[0] ?? null, cursor?.[0] ?? 0, cursor?.[1] ?? "", input.limit + 1],
  );
  const page = rows.slice(0, input.limit);
  return {
    invalidRange: false as const,
    events: page.map(mapEvent),
    nextCursor: rows.length > input.limit && page.length
      ? encodeCursor(page.at(-1)!.start_at, page.at(-1)!.id) : undefined,
    hasMore: rows.length > input.limit,
  };
}

export interface CalendarMutationInput {
  scope: "shared" | "private";
  title: string;
  notes: string;
  startAt: number;
  endAt: number;
  timezone: string;
  allDay: boolean;
}

async function appendCalendarSync(
  db: DatabaseTransaction,
  row: CalendarEventRow,
  actor: { accountId: string; deviceId?: string },
  operation: "upsert" | "delete" = "upsert",
  now = Date.now(),
) {
  await appendSyncEvent(db, {
    coupleId: row.scope === "shared" ? (row as CalendarEventRow & { couple_id?: string }).couple_id : null,
    accountId: row.scope === "private" ? actor.accountId : null,
    entityType: "calendar_event",
    entityId: row.id,
    operation,
    payload: operation === "delete" ? { id: row.id } : mapEvent(row),
    actorAccountId: actor.accountId,
    actorDeviceId: actor.deviceId,
    createdAt: now,
  });
}

export async function createCalendarEvent(user: AuthUser, input: CalendarMutationInput) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity || (input.scope === "shared" && !identity.coupleId)) return null;
    const now = Date.now();
    const id = `cal_${nanoid(16)}`;
    await db.run(
      `INSERT INTO calendar_events
       (id, couple_id, owner_account_id, created_by_account_id, scope, title, notes,
        start_at, end_at, timezone, all_day, status, created_at, updated_at, version)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'scheduled', ?, ?, 0)`,
      [id, input.scope === "shared" ? identity.coupleId : null,
        input.scope === "private" ? identity.accountId : null, identity.accountId, input.scope,
        input.title, input.notes, input.startAt, input.endAt, input.timezone, input.allDay, now, now],
    );
    if (input.scope === "shared") {
      await db.run(
        `INSERT INTO calendar_event_participants (event_id, account_id, participation_status, updated_at)
         SELECT ?, member.account_id, 'accepted', ? FROM couple_members member
         WHERE member.couple_id = ? AND member.state = 'active'`,
        [id, now, identity.coupleId],
      );
    } else {
      await db.run(
        `INSERT INTO calendar_event_participants (event_id, account_id, participation_status, updated_at)
         VALUES (?, ?, 'accepted', ?)`,
        [id, identity.accountId, now],
      );
    }
    const row = await visibleEvent(db, identity, id);
    if (!row) return null;
    (row as CalendarEventRow & { couple_id?: string }).couple_id = identity.coupleId ?? undefined;
    await appendCalendarSync(db, row, { accountId: identity.accountId, deviceId: user.deviceId }, "upsert", now);
    return mapEvent(row);
  });
}

export async function updateCalendarEvent(
  user: AuthUser,
  id: string,
  input: Partial<Omit<CalendarMutationInput, "scope">> & { baseVersion: number },
) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity) return null;
    const row = await visibleEvent(db, identity, id, true);
    if (!row) return null;
    if (row.version !== input.baseVersion) return { conflict: true as const, event: mapEvent(row) };
    const proposed = {
      startAt: input.startAt ?? row.start_at,
      endAt: input.endAt ?? row.end_at,
      timezone: input.timezone ?? row.timezone,
      allDay: input.allDay ?? row.all_day,
    };
    if (!validEventRange(proposed)) return { invalidTime: true as const };
    const now = Date.now();
    await db.run(
      `UPDATE calendar_events SET title = ?, notes = ?, start_at = ?, end_at = ?, timezone = ?,
       all_day = ?, updated_at = ?, version = version + 1 WHERE id = ?`,
      [input.title ?? row.title, input.notes ?? row.notes, input.startAt ?? row.start_at,
        input.endAt ?? row.end_at, input.timezone ?? row.timezone, input.allDay ?? row.all_day,
        now, id],
    );
    const updated = await visibleEvent(db, identity, id);
    if (!updated) return null;
    (updated as CalendarEventRow & { couple_id?: string }).couple_id = identity.coupleId ?? undefined;
    await appendCalendarSync(db, updated, { accountId: identity.accountId, deviceId: user.deviceId }, "upsert", now);
    return { conflict: false as const, invalidTime: false as const, event: mapEvent(updated) };
  });
}

export async function completeCalendarEvent(user: AuthUser, id: string, completed: boolean, baseVersion: number) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity) return null;
    const row = await visibleEvent(db, identity, id, true);
    if (!row) return null;
    if (row.version !== baseVersion) return { conflict: true as const, event: mapEvent(row) };
    const now = Date.now();
    await db.run(
      `UPDATE calendar_events SET status = ?, completed_at = ?, updated_at = ?, version = version + 1
       WHERE id = ?`,
      [completed ? "completed" : "scheduled", completed ? now : null, now, id],
    );
    const updated = await visibleEvent(db, identity, id);
    if (!updated) return null;
    (updated as CalendarEventRow & { couple_id?: string }).couple_id = identity.coupleId ?? undefined;
    await appendCalendarSync(db, updated, { accountId: identity.accountId, deviceId: user.deviceId }, "upsert", now);
    return { conflict: false as const, event: mapEvent(updated) };
  });
}

export async function deleteCalendarEvent(user: AuthUser, id: string, baseVersion: number) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity) return null;
    const row = await visibleEvent(db, identity, id, true);
    if (!row) return null;
    if (row.version !== baseVersion) return { conflict: true as const, event: mapEvent(row) };
    const now = Date.now();
    await db.run("DELETE FROM calendar_events WHERE id = ?", [id]);
    (row as CalendarEventRow & { couple_id?: string }).couple_id = identity.coupleId ?? undefined;
    await appendCalendarSync(db, row, { accountId: identity.accountId, deviceId: user.deviceId }, "delete", now);
    return { conflict: false as const };
  });
}
