// AI Actions 系统：大橘在回复里输出 actions（建提醒/备忘/删减/完成），
// 先以「确认卡」挂在 AI 消息的 meta_json 上展示给主人，主人点确认后才真正写入 personal_items。
// 移植自旧后端 chat/src/ai/actions.js，适配新的 itemService + PostgreSQL + Socket.IO。

import type { Server } from "socket.io";
import { socketEvents } from "../contracts/realtime";
import { all, get, run, type AccountRow, type MessageRow } from "../db";
import {
  createPersonalItem,
  deletePersonalItem,
  updatePersonalItem,
  type PersonalItem,
  type PersonalItemScope,
} from "../personalItems/itemService";
import { accounts } from "./memoryStore";

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

// 时间换算：把模型可能给的相对/绝对时间字符串归一成毫秒时间戳。
// 模型 system prompt 已经要求输出 "YYYY-MM-DD HH:mm"，这里兜底处理。
function parseReminderTime(time: string | undefined): number | null {
  if (!time) return null;
  const s = String(time).trim();
  if (!s) return null;

  // 已经是 "YYYY-MM-DD HH:mm" 形式
  const m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})[ T]+(\d{1,2}):(\d{1,2})/);
  if (m) {
    const dt = new Date(
      Number(m[1]),
      Number(m[2]) - 1,
      Number(m[3]),
      Number(m[4]),
      Number(m[5]),
    );
    // 当作北京时间：偏移 +8 小时
    return dt.getTime() - 8 * 60 * 60 * 1000;
  }

  // 只到分钟 "HH:mm"
  const hm = s.match(/^(\d{1,2}):(\d{1,2})$/);
  if (hm) {
    const now = new Date();
    const dt = new Date(now.getFullYear(), now.getMonth(), now.getDate(), Number(hm[1]), Number(hm[2]));
    return dt.getTime() - 8 * 60 * 60 * 1000;
  }

  // 直接数字（毫秒戳）
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

// 通过 text 关键词从 personal_items 里找一条（id 不可靠时退化方案）。
async function findReminderByText(ownerName: string, textKeyword: string): Promise<PersonalItem | undefined> {
  const match = accounts().find((a) => a.username === ownerName);
  const ownerName2 = match?.name ?? ownerName;
  // 共享 + 个人都要能命中
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

// 校验+格式化确认卡 label（不入库，只展示）。
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
      const preview = text.slice(0, 60);
      return `备忘：${preview}${text.length > 60 ? "…" : ""}`;
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

// 真正执行 action（写 personal_items）。调用方需要传 requester 的 username（@召唤者）。
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
      await createPersonalItem(fakeUser, {
        kind: "memo",
        scope,
        title: text.slice(0, 120),
        bodyMarkdown: text,
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

// 从模型输出里抽出 actions 数组。容忍 JSON 解析失败时直接返回空。
import { extractJson } from "./provider";
export function parseActions(out: string | null): AiAction[] {
  const parsed = extractJson<{ actions?: unknown }>(out);
  if (!parsed || !Array.isArray(parsed.actions)) return [];
  return parsed.actions
    .filter((a): a is AiAction => Boolean(a) && typeof a === "object" && typeof (a as AiAction).type === "string")
    .slice(0, 8);
}

// 读出一条消息的 meta 字段，并解析。
async function getMessageMeta(messageId: string): Promise<ConfirmMeta | null> {
  const row = await get<MessageRow>("SELECT * FROM messages WHERE id = ?", [messageId]);
  if (!row || !row.meta_json) return null;
  try {
    return JSON.parse(row.meta_json) as ConfirmMeta;
  } catch {
    return null;
  }
}

async function updateMessageMeta(messageId: string, meta: ConfirmMeta): Promise<void> {
  await run("UPDATE messages SET meta_json = ? WHERE id = ?", [JSON.stringify(meta), messageId]);
}

// 确认/取消 AI 提议的 action（用户在 iOS 上点确认/取消）。
export async function confirmAction(
  io: Server,
  messageId: string,
  decision: "confirm" | "cancel",
): Promise<{ ok: boolean }> {
  const meta = await getMessageMeta(messageId);
  if (!meta || !meta.confirm || meta.confirm.status !== "pending") {
    return { ok: false };
  }

  if (decision === "cancel") {
    meta.confirm.status = "cancelled";
    await updateMessageMeta(messageId, meta);
    io.emit(socketEvents.messageUpdate, { id: messageId, meta });
    return { ok: true };
  }

  // confirm：逐条执行
  let failed = 0;
  for (const item of meta.confirm.items) {
    const r = await applyAction(item.action, {
      requesterUsername: meta.confirm.requesterUsername,
    });
    if (!r.ok) failed += 1;
  }
  meta.confirm.status = "confirmed";
  meta.confirm.failed = failed;
  await updateMessageMeta(messageId, meta);
  io.emit(socketEvents.messageUpdate, { id: messageId, meta });
  return { ok: true };
}
