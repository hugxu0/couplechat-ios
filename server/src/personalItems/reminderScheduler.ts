import { all, get, run, type PersonalItemRow } from "../db";
import { sendBarkPush } from "../push/bark";
import { listBarkRecipients, listCoupleBarkRecipients, type BarkRecipient } from "../push/recipients";
import { nanoid } from "nanoid";

const SCAN_INTERVAL_MS = 60_000;
const STARTUP_LOOKBACK_MS = 7 * 24 * 60 * 60 * 1_000;
const DELIVERY_LEASE_MS = 2 * 60 * 1_000;

export interface ReminderSchedulerDependencies {
  dueReminders(after: number, before: number): Promise<PersonalItemRow[]>;
  recipients(reminder: PersonalItemRow): Promise<BarkRecipient[]>;
  claimDelivery(
    reminderId: string,
    dueAt: number,
    recipient: string,
    endpointKey: string,
    now: number,
  ): Promise<string | null>;
  finishDelivery(
    reminderId: string,
    dueAt: number,
    recipient: string,
    endpointKey: string,
    claimToken: string,
    succeeded: boolean,
    now: number,
    error?: string,
  ): Promise<void>;
  push(key: string, title: string, body: string): Promise<void>;
  now(): number;
  intervalMs: number;
}

const defaultDependencies: ReminderSchedulerDependencies = {
  dueReminders: (_after, before) => all<PersonalItemRow>(
    `SELECT * FROM personal_items
     WHERE kind = 'reminder' AND is_done = 0
       AND due_at IS NOT NULL AND due_at > ? AND due_at <= ?`,
    [before - STARTUP_LOOKBACK_MS, before],
  ),
  recipients: (reminder) => reminder.scope === "shared" && reminder.couple_id
    ? listCoupleBarkRecipients(reminder.couple_id)
    : listBarkRecipients([reminder.owner]),
  claimDelivery: async (reminderId, dueAt, recipient, endpointKey, now) => {
    const claimToken = `claim_${nanoid(18)}`;
    const claimed = await get<{ claim_token: string }>(
      `INSERT INTO reminder_bark_deliveries
       (reminder_id, due_at, recipient, endpoint_key, status, attempt_count,
        claim_token, lease_until, next_attempt_at, updated_at)
       VALUES (?, ?, ?, ?, 'sending', 1, ?, ?, NULL, ?)
       ON CONFLICT(reminder_id, due_at, recipient, endpoint_key) DO UPDATE SET
         status = 'sending',
         attempt_count = reminder_bark_deliveries.attempt_count + 1,
         claim_token = excluded.claim_token,
         lease_until = excluded.lease_until,
         next_attempt_at = NULL,
         last_error = NULL,
         updated_at = excluded.updated_at
       WHERE reminder_bark_deliveries.status <> 'delivered'
         AND (
           (reminder_bark_deliveries.status = 'failed'
             AND COALESCE(reminder_bark_deliveries.next_attempt_at, 0) <= ?)
           OR (reminder_bark_deliveries.status = 'sending'
             AND COALESCE(reminder_bark_deliveries.lease_until, 0) < ?)
         )
       RETURNING claim_token`,
      [reminderId, dueAt, recipient, endpointKey, claimToken, now + DELIVERY_LEASE_MS, now, now, now],
    );
    return claimed?.claim_token ?? null;
  },
  finishDelivery: async (
    reminderId, dueAt, recipient, endpointKey, claimToken, succeeded, now, error,
  ) => {
    if (succeeded) {
      await run(
        `UPDATE reminder_bark_deliveries SET status = 'delivered', delivered_at = ?,
         lease_until = NULL, next_attempt_at = NULL, last_error = NULL, updated_at = ?
         WHERE reminder_id = ? AND due_at = ? AND recipient = ? AND endpoint_key = ?
           AND status = 'sending' AND claim_token = ?`,
        [now, now, reminderId, dueAt, recipient, endpointKey, claimToken],
      );
      await run(
        `UPDATE device_push_endpoints SET failure_count = 0, last_success_at = ?, updated_at = ?
         WHERE endpoint_fingerprint = ?`,
        [now, now, endpointKey],
      );
      return;
    }
    await run(
      `UPDATE reminder_bark_deliveries SET status = 'failed', lease_until = NULL,
       next_attempt_at = ? + LEAST(3600000, 60000 * POWER(2, LEAST(attempt_count - 1, 6)))::BIGINT,
       last_error = ?, delivered_at = NULL, updated_at = ?
       WHERE reminder_id = ? AND due_at = ? AND recipient = ? AND endpoint_key = ?
         AND status = 'sending' AND claim_token = ?`,
      [now, error?.slice(0, 1_000) ?? "unknown_error", now,
        reminderId, dueAt, recipient, endpointKey, claimToken],
    );
    await run(
      `UPDATE device_push_endpoints SET failure_count = failure_count + 1, updated_at = ?
       WHERE endpoint_fingerprint = ?`,
      [now, endpointKey],
    );
  },
  push: sendBarkPush,
  now: Date.now,
  intervalMs: SCAN_INTERVAL_MS,
};

function groupedRecipients(recipients: BarkRecipient[]): BarkRecipient[][] {
  const groups = new Map<string, BarkRecipient[]>();
  for (const recipient of recipients) {
    const group = groups.get(recipient.endpointKey) ?? [];
    if (!group.some((item) => item.username === recipient.username)) group.push(recipient);
    groups.set(recipient.endpointKey, group);
  }
  return [...groups.values()];
}

export function createReminderScheduler(
  overrides: Partial<ReminderSchedulerDependencies> = {},
) {
  const dependencies = { ...defaultDependencies, ...overrides };
  let lastScanTs = dependencies.now() - STARTUP_LOOKBACK_MS;
  let timer: NodeJS.Timeout | null = null;
  let running = false;

  async function scanOnce(): Promise<void> {
    if (running) return;
    running = true;
    try {
      const now = dependencies.now();
      const due = await dependencies.dueReminders(lastScanTs, now);
      for (const reminder of due) {
        if (!reminder.due_at) continue;
        const recipients = await dependencies.recipients(reminder);
        const date = new Date(reminder.due_at + 8 * 60 * 60 * 1000);
        const part = (value: number) => String(value).padStart(2, "0");
        const body = `${reminder.title} · ${part(date.getUTCHours())}:${part(date.getUTCMinutes())}`;

        await Promise.allSettled(groupedRecipients(recipients).map(async (group) => {
          const endpoint = group[0];
          if (!endpoint) return;
          const claims = (await Promise.all(group.map(async (recipient) => ({
            recipient,
            token: await dependencies.claimDelivery(
              reminder.id, reminder.due_at!, recipient.username, recipient.endpointKey, now,
            ),
          })))).filter((item): item is { recipient: BarkRecipient; token: string } => Boolean(item.token));
          if (claims.length === 0) return;
          try {
            await dependencies.push(endpoint.barkKey, "大橘提醒你", body);
            await Promise.all(claims.map(({ recipient, token }) => dependencies.finishDelivery(
              reminder.id, reminder.due_at!, recipient.username, recipient.endpointKey,
              token, true, dependencies.now(),
            )));
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            await Promise.all(claims.map(({ recipient, token }) => dependencies.finishDelivery(
              reminder.id, reminder.due_at!, recipient.username, recipient.endpointKey,
              token, false, dependencies.now(), message,
            )));
          }
        }));
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
      lastScanTs = dependencies.now() - STARTUP_LOOKBACK_MS;
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
