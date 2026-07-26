import { all, run } from "../../db";
import type { AuthUser, ClientMessage, ClientChannel, StoredChannel } from "../../types";
import { toClientChannel } from "../../types";

export type AiReplyJobStatus =
  | "pending"
  | "queued"
  | "processing"
  | "completed"
  | "ignored"
  | "cancelled"
  | "failed"
  | "exhausted";

export interface RecoverableAiReplyJob {
  id: string;
  triggerMessageId: string;
  storedChannel: StoredChannel;
  user: AuthUser;
  channel: ClientChannel;
}

const MAX_ATTEMPTS = 5;
const LEASE_MS = 180_000;
const RETRY_DELAY_MS = 30_000;

function activeStatuses(statuses: AiReplyJobStatus[]): string {
  return statuses.map(() => "?").join(", ");
}

export async function enqueueAiReplyJob(
  db: {
    run(sql: string, params?: any[]): Promise<number>;
  },
  input: {
    message: ClientMessage;
    accountId: string;
    conversationId: string;
    storedChannel: StoredChannel;
    now: number;
  },
): Promise<void> {
  await db.run(
    `INSERT INTO ai_reply_jobs
       (id, trigger_message_id, conversation_id, requester_account_id, stored_channel,
        status, attempt_count, available_at, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?, ?)
     ON CONFLICT (trigger_message_id) DO NOTHING`,
    [
      `airj_${input.message.id}`,
      input.message.id,
      input.conversationId,
      input.accountId,
      input.storedChannel,
      input.now,
      input.now,
      input.now,
    ],
  );
}

export async function markAiReplyJobQueued(messageId: string): Promise<boolean> {
  return (await run(
    `UPDATE ai_reply_jobs
        SET status = 'queued', lease_until = NULL, available_at = ?, updated_at = ?
      WHERE trigger_message_id = ?
        AND status IN ('pending', 'queued', 'failed')
        AND attempt_count < ?`,
    [Date.now(), Date.now(), messageId, MAX_ATTEMPTS],
  )) === 1;
}

export async function markAiReplyJobIgnored(
  messageId: string,
  reason = "not_triggered",
): Promise<boolean> {
  return (await run(
    `UPDATE ai_reply_jobs
        SET status = 'ignored', lease_until = NULL, last_error = ?, updated_at = ?, completed_at = ?
      WHERE trigger_message_id = ?
        AND status IN ('pending', 'queued', 'failed')`,
    [reason.slice(0, 200), Date.now(), Date.now(), messageId],
  )) === 1;
}

export async function markAiReplyJobCancelled(
  messageId: string,
  reason = "recalled",
): Promise<boolean> {
  return (await run(
    `UPDATE ai_reply_jobs
        SET status = 'cancelled', lease_until = NULL, last_error = ?, updated_at = ?, completed_at = ?
      WHERE trigger_message_id = ?
        AND status IN ('pending', 'queued', 'processing', 'failed')`,
    [reason.slice(0, 200), Date.now(), Date.now(), messageId],
  )) === 1;
}

/**
 * Claims a job for the in-memory channel queue. A stale processing lease is
 * recoverable after a crash; a live lease is left alone to avoid duplicate model
 * calls if a recovery pass overlaps a runner.
 */
export async function claimAiReplyJob(messageId: string): Promise<boolean> {
  const now = Date.now();
  return (await run(
    `UPDATE ai_reply_jobs
        SET status = 'processing', attempt_count = attempt_count + 1,
            lease_until = ?, available_at = ?, updated_at = ?, last_error = NULL
      WHERE trigger_message_id = ?
        AND attempt_count < ?
        AND (
          status IN ('pending', 'queued', 'failed')
          OR (status = 'processing' AND COALESCE(lease_until, 0) < ?)
        )`,
    [now + LEASE_MS, now, now, messageId, MAX_ATTEMPTS, now],
  )) === 1;
}

export async function markAiReplyJobFailed(
  messageId: string,
  error = "reply_failed",
): Promise<boolean> {
  const now = Date.now();
  return (await run(
    `UPDATE ai_reply_jobs
        SET status = CASE WHEN attempt_count >= ? THEN 'exhausted' ELSE 'failed' END,
            lease_until = NULL, available_at = ?, last_error = ?, updated_at = ?
      WHERE trigger_message_id = ? AND status = 'processing'`,
    [MAX_ATTEMPTS, now + RETRY_DELAY_MS, error.slice(0, 500), now, messageId],
  )) === 1;
}

/**
 * A single production process owns the reply queue. On startup every
 * processing row belongs to the previous process; during normal operation
 * only expired leases are released. Attempts at the limit are terminalized so
 * no row can remain recoverable forever.
 */
export async function releaseAiReplyJobLeases(force = false): Promise<number> {
  const now = Date.now();
  return run(
    `UPDATE ai_reply_jobs
        SET status = CASE WHEN attempt_count >= ? THEN 'exhausted' ELSE 'queued' END,
            lease_until = NULL,
            available_at = ?,
            last_error = CASE
              WHEN attempt_count >= ? THEN COALESCE(last_error, 'reply_attempts_exhausted')
              WHEN ? THEN COALESCE(last_error, 'process_restarted')
              ELSE COALESCE(last_error, 'reply_lease_expired')
            END,
            updated_at = ?,
            completed_at = CASE WHEN attempt_count >= ? THEN ? ELSE completed_at END
      WHERE status = 'processing'
        AND (? OR COALESCE(lease_until, 0) < ?)`,
    [
      MAX_ATTEMPTS,
      now,
      MAX_ATTEMPTS,
      force,
      now,
      MAX_ATTEMPTS,
      now,
      force,
      now,
    ],
  );
}

/**
 * Startup recovery intentionally returns only the trigger and identity. The
 * normal message mapper remains the single source of truth for attachments,
 * transcripts and signed media URLs.
 */
export async function recoverableAiReplyJobs(limit = 500): Promise<RecoverableAiReplyJob[]> {
  const rows = await all<{
    id: string;
    trigger_message_id: string;
    stored_channel: string;
    message_channel: StoredChannel;
    username: string;
    display_name: string;
    account_id: string;
    couple_id: string | null;
    member_id: string | null;
  }>(
    `SELECT job.id, job.trigger_message_id, job.stored_channel,
            message.channel AS message_channel,
            account.username, account.display_name, account.id AS account_id,
            member.couple_id, member.id AS member_id
       FROM ai_reply_jobs job
       JOIN messages message ON message.id = job.trigger_message_id
       JOIN accounts account ON account.id = job.requester_account_id
        AND account.status = 'active'
       LEFT JOIN couple_members member ON member.account_id = account.id
        AND member.state = 'active'
      WHERE job.status IN (${activeStatuses(["pending", "queued", "failed"])})
        AND job.attempt_count < ?
        AND job.available_at <= ?
      ORDER BY job.created_at ASC
      LIMIT ?`,
    [
      "pending",
      "queued",
      "failed",
      MAX_ATTEMPTS,
      Date.now(),
      Math.max(1, Math.min(2_000, limit)),
    ],
  );
  return rows.flatMap((row) => {
    const storedChannel = row.stored_channel as StoredChannel;
    const channel = toClientChannel(row.message_channel);
    if (
      (channel === "couple" && storedChannel !== "couple")
      || (channel === "ai" && !storedChannel.startsWith("ai:"))
    ) return [];
    return [{
      id: row.id,
      triggerMessageId: row.trigger_message_id,
      storedChannel,
      channel,
      user: {
        username: row.username,
        name: row.display_name,
        accountId: row.account_id,
        coupleId: row.couple_id ?? undefined,
        memberId: row.member_id ?? undefined,
      },
    }];
  });
}

export async function markMissingAiReplyJobCancelled(messageId: string): Promise<void> {
  await markAiReplyJobCancelled(messageId, "trigger_message_missing");
}

export const aiReplyJobLeaseMs = LEASE_MS;
