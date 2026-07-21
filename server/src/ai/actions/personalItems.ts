// 解析、展示并执行需要主人确认的提醒和备忘操作。

import type { Server } from "socket.io";
import { socketEvents } from "../../contracts/realtime";
import { all, get, run, type AccountRow, type MessageRow } from "../../db";
import {
  createPersonalItem,
  deletePersonalItem,
  getPersonalItem,
  updatePersonalItem,
  type PersonalItem,
  type PersonalItemScope,
} from "../../personalItems/itemService";
import { activeIdentity } from "../../auth/identity";
import type { AuthUser } from "../../types";

export interface AiAction {
  type:
    | "add_reminder"
    | "add_memo"
    | "complete_reminder"
    | "edit_reminder"
    | "delete_reminder"
    | "edit_memo"
    | "delete_memo";
  title?: string;
  text?: string;
  time?: string;
  id?: string;
  newText?: string;
  newTitle?: string;
  newTime?: string;
  ownerName?: string;
  scope?: "personal" | "shared";
}

export interface ConfirmItem {
  action: AiAction;
  label: string;
  result?: "succeeded" | "failed";
  error?: "action_rejected" | "execution_failed";
}

export interface ConfirmMeta {
  confirm: {
    status: "pending" | "processing" | "confirmed" | "cancelled";
    items: ConfirmItem[];
    requesterName: string;
    requesterUsername: string;
    failed?: number;
  };
}

export type ConfirmActionResult =
  | { ok: false }
  | { ok: true; messageId: string; meta: ConfirmMeta };

// 模型应输出北京时间；此处只负责确定性格式转换。
function parseReminderTime(time: string | undefined): number | null {
  if (!time) return null;
  const s = String(time).trim();
  if (!s) return null;

  const m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})[ T]+(\d{1,2}):(\d{1,2})/);
  if (m) {
    const timestamp = Date.parse(
      `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}T${m[4].padStart(2, "0")}:${m[5].padStart(2, "0")}:00+08:00`,
    );
    return Number.isFinite(timestamp) ? timestamp : null;
  }

  const hm = s.match(/^(\d{1,2}):(\d{1,2})$/);
  if (hm) {
    const now = new Date(Date.now() + 8 * 60 * 60 * 1000);
    const date = now.toISOString().slice(0, 10);
    const timestamp = Date.parse(`${date}T${hm[1].padStart(2, "0")}:${hm[2].padStart(2, "0")}:00+08:00`);
    return Number.isFinite(timestamp) ? timestamp : null;
  }

  const num = Number(s);
  if (Number.isFinite(num) && num > 0) return num;

  return null;
}

function resolveScope(scope: "personal" | "shared" | undefined): PersonalItemScope {
  return scope === "personal" ? "personal" : "shared";
}

function memoTitle(action: AiAction): string {
  const explicit = String(action.title ?? "").trim().replace(/^#{1,6}\s+/, "");
  if (explicit) return explicit.slice(0, 160);
  const firstLine = String(action.text ?? "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line && !/^\|?\s*:?-{3,}/.test(line));
  if (!firstLine || firstLine.startsWith("|")) return "大橘备忘";
  return firstLine.replace(/^#{1,6}\s+/, "").replace(/^[-*+]\s+/, "").slice(0, 160);
}

function memoBody(action: AiAction, title: string): string {
  const lines = String(action.text ?? "").trim().split(/\r?\n/);
  const normalize = (value: string) => value
    .trim()
    .replace(/^#{1,6}\s+/, "")
    .replace(/^\*\*(.+)\*\*$/, "$1")
    .trim()
    .toLocaleLowerCase();
  if (lines.length && normalize(lines[0]) === normalize(title)) lines.shift();
  while (lines[0]?.trim() === "") lines.shift();
  return lines.join("\n").trim();
}

// ID 缺失时只在当前可见事项中做精确范围的文字定位。
async function findReminderByText(ownerName: string, textKeyword: string): Promise<PersonalItem | undefined> {
  const rows = await all<AccountRow & { title: string }>(
    `SELECT * FROM personal_items
     WHERE kind = 'reminder' AND (
       owner = ? OR scope = 'shared'
     ) AND title LIKE ? AND is_done = 0
     ORDER BY due_at ASC, updated_at DESC LIMIT 1`,
    [ownerName, `%${textKeyword}%`],
  );
  return rows.length ? (rows[0] as unknown as PersonalItem) : undefined;
}

async function findMemoByText(ownerName: string, textKeyword: string): Promise<PersonalItem | undefined> {
  const rows = await all<{ id: string }>(
    `SELECT * FROM personal_items
     WHERE kind = 'memo' AND (
       owner = ? OR scope = 'shared'
     ) AND title LIKE ?
     ORDER BY updated_at DESC LIMIT 1`,
    [ownerName, `%${textKeyword}%`],
  );
  return rows.length ? (rows[0] as unknown as PersonalItem) : undefined;
}

// 生成确认卡文案，不写数据库。
export function describeAction(action: AiAction): string | null {
  if (!action || typeof action !== "object") return null;
  switch (action.type) {
    case "add_reminder": {
      const title = String(action.title ?? "").trim();
      if (!title) return null;
      const time = action.time ? ` · ${action.time}` : "";
      const owner = action.ownerName ? `（给${action.ownerName}）` : "";
      return `提醒：${title}${time}${owner}`;
    }
    case "add_memo": {
      const text = String(action.text ?? action.title ?? "").trim();
      if (!text) return null;
      return `备忘：${memoTitle(action)}`;
    }
    case "complete_reminder": {
      const target = action.id ? `#${action.id}` : String(action.text ?? "").slice(0, 60);
      return `完成提醒：${target}`;
    }
    case "edit_reminder": {
      const target = action.id ? `#${action.id}` : String(action.text ?? "").slice(0, 60);
      return `修改提醒：${target}`;
    }
    case "delete_reminder": {
      const target = action.id ? `#${action.id}` : String(action.text ?? "").slice(0, 60);
      return `删除提醒：${target}`;
    }
    case "edit_memo": {
      const target = action.id ? `#${action.id}` : String(action.text ?? "").slice(0, 60);
      return `修改备忘：${target}`;
    }
    case "delete_memo": {
      const target = action.id ? `#${action.id}` : String(action.text ?? "").slice(0, 60);
      return `删除备忘：${target}`;
    }
    default:
      return null;
  }
}

// 用户确认后才写 personal_items。
export async function applyAction(
  action: AiAction,
  context: { requesterUsername: string },
): Promise<{ ok: boolean; label: string }> {
  const scope = resolveScope(action.scope);
  // 工具动作始终以当前登录账号授权。模型输出的 ownerName 只能用于确认卡文案，
  // 不能伪装成另一位账号去读写对方的私人事项。
  const fakeUser = { username: context.requesterUsername, name: context.requesterUsername };

  switch (action.type) {
    case "add_reminder": {
      const title = String(action.title ?? "").trim();
      if (!title) return { ok: false, label: "（无效提醒）" };
      const dueAt = parseReminderTime(action.time);
      if (action.time && dueAt === null) return { ok: false, label: "（提醒时间格式无效）" };
      const created = await createPersonalItem(fakeUser, {
        kind: "reminder",
        scope,
        title,
        dueAt,
      });
      if (!created) return { ok: false, label: "（提醒未创建）" };
      return { ok: true, label: describeAction(action) ?? "提醒已创建" };
    }
    case "add_memo": {
      const text = String(action.text ?? action.title ?? "").trim();
      if (!text) return { ok: false, label: "（无效备忘）" };
      const title = memoTitle(action);
      const created = await createPersonalItem(fakeUser, {
        kind: "memo",
        scope,
        title,
        bodyMarkdown: memoBody(action, title),
      });
      if (!created) return { ok: false, label: "（备忘未创建）" };
      return { ok: true, label: describeAction(action) ?? "备忘已创建" };
    }
    case "complete_reminder": {
      if (action.id) {
        const r = await updatePersonalItem(fakeUser, action.id, { isDone: true });
        if (r) return { ok: true, label: describeAction(action) ?? "已完成" };
      }
      const keyword = String(action.text ?? "").trim();
      if (keyword) {
        const target = await findReminderByText(fakeUser.username, keyword);
        if (target) {
          await updatePersonalItem(fakeUser, target.id, { isDone: true });
          return { ok: true, label: describeAction(action) ?? "已完成" };
        }
      }
      return { ok: false, label: "（没找到这条提醒）" };
    }
    case "edit_reminder": {
      const patch: { title?: string; dueAt?: number | null } = {};
      const newTitle = String(action.newTitle ?? "").trim();
      if (newTitle) patch.title = newTitle;
      if (action.newTime !== undefined) {
        const rawTime = String(action.newTime).trim();
        const parsedTime = rawTime ? parseReminderTime(rawTime) : null;
        if (rawTime && parsedTime === null) return { ok: false, label: "（新的提醒时间格式无效）" };
        patch.dueAt = parsedTime;
      }
      if (!Object.keys(patch).length) return { ok: false, label: "（没有提供新的提醒内容）" };
      let target = action.id ? await getPersonalItem(fakeUser, action.id) : undefined;
      if (!target) {
        const keyword = String(action.text ?? "").trim();
        if (keyword) target = await findReminderByText(fakeUser.username, keyword);
      }
      if (!target || target.kind !== "reminder") return { ok: false, label: "（没找到这条提醒）" };
      const updated = await updatePersonalItem(fakeUser, target.id, patch);
      return updated
        ? { ok: true, label: describeAction(action) ?? "提醒已修改" }
        : { ok: false, label: "（提醒修改失败）" };
    }
    case "delete_reminder": {
      if (action.id) {
        const ok = await deletePersonalItem(fakeUser, action.id);
        if (ok) return { ok: true, label: describeAction(action) ?? "已删除" };
      }
      const keyword = String(action.text ?? "").trim();
      if (keyword) {
        const target = await findReminderByText(fakeUser.username, keyword);
        if (target) {
          await deletePersonalItem(fakeUser, target.id);
          return { ok: true, label: describeAction(action) ?? "已删除" };
        }
      }
      return { ok: false, label: "（没找到这条提醒）" };
    }
    case "edit_memo": {
      const newText = action.newText === undefined ? undefined : String(action.newText).trim();
      const newTitle = String(action.newTitle ?? "").trim();
      if (newText === undefined && !newTitle) return { ok: false, label: "（没有提供新的备忘内容）" };
      let target = action.id ? await getPersonalItem(fakeUser, action.id) : undefined;
      if (!target) {
        const keyword = String(action.text ?? "").trim();
        if (keyword) target = await findMemoByText(fakeUser.username, keyword);
      }
      if (!target || target.kind !== "memo") return { ok: false, label: "（没找到这条备忘）" };
      const updated = await updatePersonalItem(fakeUser, target.id, {
        title: newTitle || target.title,
        bodyMarkdown: newText ?? target.bodyMarkdown,
      });
      return updated
        ? { ok: true, label: describeAction(action) ?? "已修改" }
        : { ok: false, label: "（备忘修改失败）" };
    }
    case "delete_memo": {
      let target = action.id ? await getPersonalItem(fakeUser, action.id) : undefined;
      if (!target) {
        const keyword = String(action.text ?? "").trim();
        if (keyword) target = await findMemoByText(fakeUser.username, keyword);
      }
      if (!target || target.kind !== "memo") return { ok: false, label: "（没找到这条备忘）" };
      const deleted = await deletePersonalItem(fakeUser, target.id);
      return deleted
        ? { ok: true, label: describeAction(action) ?? "备忘已删除" }
        : { ok: false, label: "（备忘删除失败）" };
    }
    default:
      return { ok: false, label: "（不认识的 action）" };
  }
}

async function getMessageMeta(user: AuthUser, messageId: string): Promise<{
  meta: ConfirmMeta;
  channel: string;
  coupleId: string | null;
  ownerAccountId: string | null;
} | null> {
  const identity = await activeIdentity(user);
  if (!identity) return null;
  const row = await get<MessageRow & { couple_id: string | null; owner_account_id: string | null }>(
    `SELECT message.*, conversation.couple_id, conversation.owner_account_id
       FROM messages message
       JOIN conversations conversation ON conversation.id = message.conversation_id
      WHERE message.id = ?
        AND ((conversation.kind = 'couple' AND conversation.couple_id = ?)
          OR (conversation.kind = 'ai' AND conversation.owner_account_id = ?))`,
    [messageId, identity.coupleId, identity.accountId],
  );
  if (!row || !row.meta_json) return null;
  try {
    return {
      meta: JSON.parse(row.meta_json) as ConfirmMeta,
      channel: row.channel,
      coupleId: row.couple_id ?? identity.coupleId,
      ownerAccountId: row.owner_account_id,
    };
  } catch {
    return null;
  }
}

async function updateMessageMeta(messageId: string, meta: ConfirmMeta): Promise<void> {
  await run("UPDATE messages SET meta_json = ? WHERE id = ?", [JSON.stringify(meta), messageId]);
}

async function claimPendingConfirmation(messageId: string, meta: ConfirmMeta): Promise<boolean> {
  const claimed = structuredClone(meta);
  claimed.confirm.status = "processing";
  return await run(
    `UPDATE messages SET meta_json = ?
      WHERE id = ? AND meta_json::jsonb #>> '{confirm,status}' = 'pending'`,
    [JSON.stringify(claimed), messageId],
  ) === 1;
}

export async function confirmAction(
  io: Server,
  user: AuthUser,
  messageId: string,
  decision: "confirm" | "cancel",
): Promise<ConfirmActionResult> {
  const stored = await getMessageMeta(user, messageId);
  if (!stored || !stored.meta.confirm || stored.meta.confirm.status !== "pending") {
    return { ok: false };
  }
  const { meta, channel } = stored;
  if (meta.confirm.requesterUsername !== user.username) return { ok: false };
  if (!await claimPendingConfirmation(messageId, meta)) return { ok: false };
  meta.confirm.status = "processing";
  const messageRoom = channel === "couple"
    ? `couple:${stored.coupleId}`
    : `account:${stored.ownerAccountId}`;

  if (decision === "cancel") {
    meta.confirm.status = "cancelled";
    await updateMessageMeta(messageId, meta);
    io.to(messageRoom).emit(socketEvents.messageUpdate, { id: messageId, meta });
    return { ok: true, messageId, meta };
  }

  let failed = 0;
  for (const item of meta.confirm.items) {
    let applied = false;
    try {
      const result = await applyAction(item.action, {
        requesterUsername: meta.confirm.requesterUsername,
      });
      applied = result.ok;
      item.result = result.ok ? "succeeded" : "failed";
      item.error = result.ok ? undefined : "action_rejected";
    } catch (error) {
      item.result = "failed";
      item.error = "execution_failed";
      console.warn(
        `[ai-confirm] action failed for ${messageId}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    if (!applied) {
      failed += 1;
      // Persist each failure while the card is processing. If the process stops before
      // finalization, operators can see exactly which item did not run.
      try { await updateMessageMeta(messageId, meta); } catch { /* final write below is authoritative */ }
      continue;
    }
    try {
      const scope = resolveScope(item.action.scope);
      const owner = meta.confirm.requesterUsername;
      const ownerAccount = scope === "personal"
        ? await get<{ id: string }>("SELECT id FROM accounts WHERE username = ? AND status = 'active'", [owner])
        : null;
      const room = scope === "shared"
        ? `couple:${stored.coupleId}`
        : ownerAccount ? `account:${ownerAccount.id}` : null;
      if (!room) throw new Error(`active account not found for ${owner}`);
      io.to(room).emit(socketEvents.personalItemChanged, {
        action: item.action.type,
        source: "ai",
        item: { scope, owner },
      });
    } catch (error) {
      // The mutation already succeeded. A notification failure must not strand the card.
      console.warn(
        `[ai-confirm] notification failed for ${messageId}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    try { await updateMessageMeta(messageId, meta); } catch { /* final write below is authoritative */ }
  }
  meta.confirm.status = "confirmed";
  meta.confirm.failed = failed;
  await updateMessageMeta(messageId, meta);
  io.to(messageRoom).emit(socketEvents.messageUpdate, { id: messageId, meta });
  return { ok: true, messageId, meta };
}
