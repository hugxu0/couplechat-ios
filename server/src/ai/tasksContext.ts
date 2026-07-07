// needTasks 命中时，给回复引擎当前提醒/备忘的概览。
// 触发完成后大橘知道当前有哪些提醒、哪些备忘——它执行 complete/delete/edit 时
// 才不会闭着眼睛靠聊天里没出现的细节去猜 id。

import { all } from "../db";
import { accounts } from "./memoryStore";
import { CONTEXT } from "./params";

interface ReminderRow {
  id: string;
  title: string;
  due_at: number | null;
  owner: string;
  scope: string;
}

interface MemoRow {
  id: string;
  title: string;
  body_markdown: string;
  owner: string;
  scope: string;
}

function beijingTime(ts: number | null): string {
  if (!ts || !Number.isFinite(ts)) return "";
  const d = new Date(ts + 8 * 60 * 60 * 1000);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
}

export async function tasksTextRich(): Promise<string> {
  const usernames = accounts().map((a) => a.username);
  if (usernames.length === 0) return "";
  const placeholders = usernames.map(() => "?").join(",");

  const reminders = await all<ReminderRow>(
    `SELECT id, title, due_at, owner, scope FROM personal_items
     WHERE kind = 'reminder' AND is_done = 0
       AND (scope = 'shared' OR owner IN (${placeholders}))
     ORDER BY COALESCE(due_at, updated_at) ASC
     LIMIT ?`,
    [...usernames, CONTEXT.taskReminderCount],
  );

  const memos = await all<MemoRow>(
    `SELECT id, title, body_markdown, owner, scope FROM personal_items
     WHERE kind = 'memo' AND is_done = 0
       AND (scope = 'shared' OR owner IN (${placeholders}))
     ORDER BY updated_at DESC
     LIMIT ?`,
    [...usernames, CONTEXT.taskMemoCount],
  );

  if (reminders.length === 0 && memos.length === 0) return "";

  const parts: string[] = [];

  if (reminders.length) {
    parts.push(
      "【当前未完成的提醒】（执行 complete_reminder/delete_reminder 时优先填 id）\n" +
        reminders
          .map((r) => `- id:${r.id} 「${(r.title || "").slice(0, 60)}」${r.due_at ? ` · ${beijingTime(r.due_at)}` : ""}`)
          .join("\n"),
    );
  }

  if (memos.length) {
    parts.push(
      "【当前备忘录】（执行 edit_memo/delete_memo 时优先填 id）\n" +
        memos
          .map((m) => `- id:${m.id} ${(m.title || "").slice(0, CONTEXT.taskMemoTextMax)}`)
          .join("\n"),
    );
  }

  return parts.join("\n\n");
}

// 简短概览（不带明细），用在意图判断日志和不那么需要明细的场景。
export async function tasksContext(): Promise<string> {
  const usernames = accounts().map((a) => a.username);
  if (usernames.length === 0) return "";
  const placeholders = usernames.map(() => "?").join(",");

  const reminderRows = await all<{ c: number }>(
    `SELECT COUNT(*) as c FROM personal_items WHERE kind = 'reminder' AND is_done = 0 AND (scope = 'shared' OR owner IN (${placeholders}))`,
    usernames,
  );
  const memoRows = await all<{ c: number }>(
    `SELECT COUNT(*) as c FROM personal_items WHERE kind = 'memo' AND is_done = 0 AND (scope = 'shared' OR owner IN (${placeholders}))`,
    usernames,
  );
  const reminders = reminderRows[0]?.c ?? 0;
  const memos = memoRows[0]?.c ?? 0;

  if (reminders === 0 && memos === 0) return "";
  return `未完成提醒 ${reminders} 条 / 备忘 ${memos} 条`;
}
