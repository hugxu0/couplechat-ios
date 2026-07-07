// needTasks 命中时，给回复引擎一句「未完成提醒/备忘有几条」的概览，不吐全文（省 token）。

import { all } from "../db";
import { accounts } from "./memoryStore";

export function tasksContext(): string {
  const usernames = accounts().map((a) => a.username);
  if (usernames.length === 0) return "";
  const placeholders = usernames.map(() => "?").join(",");

  const reminders = all<{ c: number }>(
    `SELECT COUNT(*) as c FROM personal_items WHERE kind = 'reminder' AND is_done = 0 AND (scope = 'shared' OR owner IN (${placeholders}))`,
    usernames,
  )[0]?.c ?? 0;
  const memos = all<{ c: number }>(
    `SELECT COUNT(*) as c FROM personal_items WHERE kind = 'memo' AND is_done = 0 AND (scope = 'shared' OR owner IN (${placeholders}))`,
    usernames,
  )[0]?.c ?? 0;

  if (reminders === 0 && memos === 0) return "";
  return `未完成提醒 ${reminders} 条 / 备忘 ${memos} 条`;
}
