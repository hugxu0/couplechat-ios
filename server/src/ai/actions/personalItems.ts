// 解析、展示并执行需要主人确认的提醒和备忘操作。

import type { Server } from "socket.io";
import { socketEvents } from "../../contracts/realtime";
import { all, get, run, type AccountRow, type MessageRow } from "../../db";
import {
  createPersonalItem,
  deletePersonalItem,
  updatePersonalItem,
  type PersonalItem,
  type PersonalItemScope,
} from "../../personalItems/itemService";
import { accounts } from "../accounts";

export interface AiAction {
  type:
    | "add_reminder"
    | "add_memo"
    | "complete_reminder"
    | "delete_reminder"
    | "edit_memo";
  title?: string;
  text?: string;
  time?: string;
  id?: string;
  newText?: string;
  ownerName?: string;
  scope?: "personal" | "shared";
}

export interface ConfirmItem {
  action: AiAction;
  label: string;
}

export interface ConfirmMeta {
  confirm: {
    status: "pending" | "confirmed" | "cancelled";
    items: ConfirmItem[];
    requesterName: string;
    requesterUsername: string;
    failed?: number;
  };
}

// 模型应输出北京时间；此处只负责确定性格式转换。
function parseReminderTime(time: string | undefined): number | null {
  if (!time) return null;
  const s = String(time).trim();
  if (!s) return null;

  const m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})[ T]+(\d{1,2}):(\d{1,2})/);
  if (m) {
    const dt = new Date(
      Number(m[1]),
      Number(m[2]) - 1,
      Number(m[3]),
      Number(m[4]),
      Number(m[5]),
    );
    // Date 使用服务器本地时区构造，因此显式换算为北京时间时间戳。
    return dt.getTime() - 8 * 60 * 60 * 1000;
  }

  const hm = s.match(/^(\d{1,2}):(\d{1,2})$/);
  if (hm) {
    const now = new Date();
    const dt = new Date(now.getFullYear(), now.getMonth(), now.getDate(), Number(hm[1]), Number(hm[2]));
    return dt.getTime() - 8 * 60 * 60 * 1000;
  }

  const num = Number(s);
  if (Number.isFinite(num) && num > 0) return num;

  return null;
}

function resolveOwnerName(name: string | undefined, fallbackUsername: string): string {
  if (!name) return fallbackUsername;
  const match = accounts().find((a) => a.name === name || a.username === name);
  return match ? match.username : fallbackUsername;
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
    case "delete_reminder": {
      const target = action.id ? `#${action.id}` : String(action.text ?? "").slice(0, 60);
      return `删除提醒：${target}`;
    }
    case "edit_memo": {
      const target = action.id ? `#${action.id}` : String(action.text ?? "").slice(0, 60);
      return `修改备忘：${target}`;
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
  const fakeUser = { username: resolveOwnerName(action.ownerName, context.requesterUsername), name: action.ownerName ?? context.requesterUsername };
  const scope = resolveScope(action.scope);

  switch (action.type) {
    case "add_reminder": {
      const title = String(action.title ?? "").trim();
      if (!title) return { ok: false, label: "（无效提醒）" };
      const dueAt = parseReminderTime(action.time);
      await createPersonalItem(fakeUser, {
        kind: "reminder",
        scope,
        title,
        dueAt,
      });
      return { ok: true, label: describeAction(action) ?? "提醒已创建" };
    }
    case "add_memo": {
      const text = String(action.text ?? action.title ?? "").trim();
      if (!text) return { ok: false, label: "（无效备忘）" };
      const title = memoTitle(action);
      await createPersonalItem(fakeUser, {
        kind: "memo",
        scope,
        title,
        bodyMarkdown: memoBody(action, title),
      });
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
      const newText = String(action.newText ?? "").trim();
      if (!newText) return { ok: false, label: "（修改后的备忘内容为空）" };
      if (action.id) {
        const r = await updatePersonalItem(fakeUser, action.id, {
          title: newText.slice(0, 120),
          bodyMarkdown: newText,
        });
        if (r) return { ok: true, label: describeAction(action) ?? "已修改" };
      }
      const keyword = String(action.text ?? "").trim();
      if (keyword) {
        const target = await findMemoByText(fakeUser.username, keyword);
        if (target) {
          await updatePersonalItem(fakeUser, target.id, {
            title: newText.slice(0, 120),
            bodyMarkdown: newText,
          });
          return { ok: true, label: describeAction(action) ?? "已修改" };
        }
      }
      return { ok: false, label: "（没找到这条备忘）" };
    }
    default:
      return { ok: false, label: "（不认识的 action）" };
  }
}

async function getMessageMeta(messageId: string): Promise<{ meta: ConfirmMeta; channel: string } | null> {
  const row = await get<MessageRow>("SELECT * FROM messages WHERE id = ?", [messageId]);
  if (!row || !row.meta_json) return null;
  try {
    return { meta: JSON.parse(row.meta_json) as ConfirmMeta, channel: row.channel };
  } catch {
    return null;
  }
}

async function updateMessageMeta(messageId: string, meta: ConfirmMeta): Promise<void> {
  await run("UPDATE messages SET meta_json = ? WHERE id = ?", [JSON.stringify(meta), messageId]);
}

export async function confirmAction(
  io: Server,
  messageId: string,
  decision: "confirm" | "cancel",
): Promise<{ ok: boolean }> {
  const stored = await getMessageMeta(messageId);
  if (!stored || !stored.meta.confirm || stored.meta.confirm.status !== "pending") {
    return { ok: false };
  }
  const { meta, channel } = stored;
  const messageRoom = channel === "couple"
    ? "channel:couple"
    : `user:${meta.confirm.requesterUsername}`;

  if (decision === "cancel") {
    meta.confirm.status = "cancelled";
    await updateMessageMeta(messageId, meta);
    io.to(messageRoom).emit(socketEvents.messageUpdate, { id: messageId, meta });
    return { ok: true };
  }

  let failed = 0;
  for (const item of meta.confirm.items) {
    const r = await applyAction(item.action, {
      requesterUsername: meta.confirm.requesterUsername,
    });
    if (!r.ok) {
      failed += 1;
      continue;
    }
    const scope = resolveScope(item.action.scope);
    const owner = resolveOwnerName(item.action.ownerName, meta.confirm.requesterUsername);
    const room = scope === "shared" ? "channel:couple" : `user:${owner}`;
    io.to(room).emit(socketEvents.personalItemChanged, {
      action: item.action.type,
      source: "ai",
      item: { scope, owner },
    });
  }
  meta.confirm.status = "confirmed";
  meta.confirm.failed = failed;
  await updateMessageMeta(messageId, meta);
  io.to(messageRoom).emit(socketEvents.messageUpdate, { id: messageId, meta });
  return { ok: true };
}
