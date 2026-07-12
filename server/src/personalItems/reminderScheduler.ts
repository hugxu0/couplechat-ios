import { all, get, type AccountRow, type PersonalItemRow } from "../db";
import { sendBarkPush } from "../push/bark";

const SCAN_INTERVAL_MS = 60_000;

export interface ReminderSchedulerDependencies {
  dueReminders(after: number, before: number): Promise<PersonalItemRow[]>;
  account(username: string): Promise<AccountRow | undefined>;
  push(key: string, title: string, body: string): Promise<void>;
  now(): number;
  intervalMs: number;
}

const defaultDependencies: ReminderSchedulerDependencies = {
  dueReminders: (after, before) => all<PersonalItemRow>(
    `SELECT * FROM personal_items
     WHERE kind = 'reminder' AND is_done = 0
       AND due_at IS NOT NULL AND due_at > ? AND due_at <= ?`,
    [after, before],
  ),
  account: (username) => get<AccountRow>("SELECT * FROM accounts WHERE username = ?", [username]),
  push: sendBarkPush,
  now: Date.now,
  intervalMs: SCAN_INTERVAL_MS,
};

export function createReminderScheduler(
  overrides: Partial<ReminderSchedulerDependencies> = {},
) {
  const dependencies = { ...defaultDependencies, ...overrides };
  let lastScanTs = dependencies.now();
  let timer: NodeJS.Timeout | null = null;
  let running = false;

  async function scanOnce(): Promise<void> {
    if (running) return;
    running = true;
    try {
      const now = dependencies.now();
      const due = await dependencies.dueReminders(lastScanTs, now);
      for (const reminder of due) {
        const owner = await dependencies.account(reminder.owner);
        if (!owner?.bark_key || !reminder.due_at) continue;
        const date = new Date(reminder.due_at + 8 * 60 * 60 * 1000);
        const part = (value: number) => String(value).padStart(2, "0");
        const body = `${reminder.title} · ${part(date.getUTCHours())}:${part(date.getUTCMinutes())}`;
        await dependencies.push(owner.bark_key, "大橘提醒你", body).catch(() => undefined);
      }
      lastScanTs = now;
    } catch (error) {
      console.warn("[reminder] 扫描失败:", error instanceof Error ? error.message : error);
    } finally {
      running = false;
    }
  }

  return {
    start(): void {
      if (timer) return;
      lastScanTs = dependencies.now();
      void scanOnce();
      timer = setInterval(() => void scanOnce(), dependencies.intervalMs);
      timer.unref();
      console.log(`[reminder] 到点提醒扫描已启动（${dependencies.intervalMs / 1000}s 间隔）`);
    },
    stop(): void {
      if (!timer) return;
      clearInterval(timer);
      timer = null;
    },
    scanOnce,
  };
}
