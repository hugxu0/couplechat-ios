import { nanoid } from "nanoid";
import { get, transaction, type DatabaseTransaction } from "../db";
import { activeIdentity, activeIdentityIn, type ActiveIdentity } from "../auth/identity";
import type { AuthUser } from "../types";
import { appendSyncEvent } from "../sync/events";
import { transcriptionConfiguration } from "./provider";

export type TranscriptStatus = "pending" | "processing" | "completed" | "failed" | "unavailable";

interface TranscriptRow {
  message_id: string;
  status: TranscriptStatus;
  provider: string | null;
  language: string | null;
  text: string;
  corrected_text: string | null;
  last_error: string | null;
  version: number;
  created_at: number;
  updated_at: number;
}

interface ClaimedJob {
  jobId: string;
  messageId: string;
  path: string;
  mimeType: string;
  attemptCount: number;
}

export interface TranscriptionProvider {
  name: string;
  transcribe(input: { messageId: string; path: string; mimeType: string }): Promise<{
    text: string;
    language?: string;
  }>;
}

export function configuredTranscriptionProvider(): string | null {
  return transcriptionConfiguration()?.name ?? null;
}

export function mapTranscript(row: TranscriptRow) {
  return {
    messageId: row.message_id,
    status: row.status,
    provider: row.provider ?? undefined,
    language: row.language ?? undefined,
    text: row.corrected_text ?? row.text,
    rawText: row.corrected_text === null ? undefined : row.text,
    corrected: row.corrected_text !== null,
    error: row.last_error ?? undefined,
    version: row.version,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function transcriptVisible(row: { couple_id: string | null; owner_account_id: string | null }, identity: ActiveIdentity) {
  return (row.couple_id !== null && row.couple_id === identity.coupleId)
    || (row.owner_account_id !== null && row.owner_account_id === identity.accountId);
}

export async function enqueueTranscriptForMessage(
  db: DatabaseTransaction,
  identity: ActiveIdentity,
  messageId: string,
  now = Date.now(),
): Promise<TranscriptStatus> {
  const provider = configuredTranscriptionProvider();
  const status: TranscriptStatus = provider ? "pending" : "unavailable";
  await db.run(
    `INSERT INTO message_transcripts
     (message_id, conversation_id, couple_id, owner_account_id, status, provider,
      last_error, created_at, updated_at)
     SELECT message.id, message.conversation_id, conversation.couple_id,
            conversation.owner_account_id, ?, ?, ?, ?, ?
       FROM messages message
       JOIN conversations conversation ON conversation.id = message.conversation_id
      WHERE message.id = ?`,
    [status, provider, provider ? null : "provider_not_configured", now, now, messageId],
  );
  await db.run(
    `INSERT INTO transcript_jobs
     (id, message_id, status, provider, available_at, last_error, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    [`trjob_${nanoid(16)}`, messageId, provider ? "queued" : "unavailable", provider,
      now, provider ? null : "provider_not_configured", now, now],
  );
  await appendSyncEvent(db, {
    coupleId: identity.coupleId,
    accountId: identity.coupleId ? null : identity.accountId,
    entityType: "message_transcript",
    entityId: messageId,
    operation: "upsert",
    payload: { messageId, status, version: 0 },
    actorAccountId: identity.accountId,
    createdAt: now,
  });
  return status;
}

export async function getTranscript(user: AuthUser, messageId: string) {
  const identity = await activeIdentity(user);
  if (!identity) return null;
  const row = await get<TranscriptRow & { couple_id: string | null; owner_account_id: string | null }>(
    `SELECT transcript.* FROM message_transcripts transcript
     WHERE transcript.message_id = ?`,
    [messageId],
  );
  return row && transcriptVisible(row, identity) ? mapTranscript(row) : null;
}

export async function retryTranscript(user: AuthUser, messageId: string) {
  const provider = configuredTranscriptionProvider();
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity) return null;
    let row = await db.get<TranscriptRow & { couple_id: string | null; owner_account_id: string | null }>(
      "SELECT * FROM message_transcripts WHERE message_id = ? FOR UPDATE",
      [messageId],
    );
    if (!row) {
      const visibleVoice = await db.get<{ id: string }>(
        `SELECT message.id FROM messages message
         JOIN conversations conversation ON conversation.id = message.conversation_id
         WHERE message.id = ? AND message.type = 'voice'
           AND (conversation.couple_id = ? OR conversation.owner_account_id = ?)
         FOR UPDATE OF message`,
        [messageId, identity.coupleId ?? "", identity.accountId],
      );
      if (!visibleVoice) return null;
      await enqueueTranscriptForMessage(db, identity, messageId);
      row = await db.get<TranscriptRow & { couple_id: string | null; owner_account_id: string | null }>(
        "SELECT * FROM message_transcripts WHERE message_id = ? FOR UPDATE",
        [messageId],
      );
    }
    if (!row || !transcriptVisible(row, identity)) return null;
    if (!provider) return { unavailable: true as const, transcript: mapTranscript(row) };
    const now = Date.now();
    await db.run(
      `UPDATE message_transcripts SET status = 'pending', provider = ?, last_error = NULL,
       version = version + 1, updated_at = ? WHERE message_id = ?`,
      [provider, now, messageId],
    );
    await db.run(
      `INSERT INTO transcript_jobs
       (id, message_id, status, provider, available_at, last_error, created_at, updated_at)
       VALUES (?, ?, 'queued', ?, ?, NULL, ?, ?)
       ON CONFLICT(message_id) DO UPDATE SET status = 'queued', provider = excluded.provider,
         available_at = excluded.available_at, lease_until = NULL, last_error = NULL,
         completed_at = NULL, updated_at = excluded.updated_at`,
      [`trjob_${nanoid(16)}`, messageId, provider, now, now, now],
    );
    const updated = await db.get<TranscriptRow>("SELECT * FROM message_transcripts WHERE message_id = ?", [messageId]);
    await appendSyncEvent(db, {
      coupleId: row.couple_id,
      accountId: row.owner_account_id,
      entityType: "message_transcript",
      entityId: messageId,
      operation: "upsert",
      payload: updated ? mapTranscript(updated) : { messageId, status: "pending" },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return updated ? { unavailable: false as const, transcript: mapTranscript(updated) } : null;
  });
}

export async function correctTranscript(user: AuthUser, messageId: string, text: string, baseVersion?: number) {
  return transaction(async (db) => {
    const identity = await activeIdentityIn(db, user);
    if (!identity) return null;
    const row = await db.get<TranscriptRow & { couple_id: string | null; owner_account_id: string | null }>(
      "SELECT * FROM message_transcripts WHERE message_id = ? FOR UPDATE",
      [messageId],
    );
    if (!row || !transcriptVisible(row, identity)) return null;
    if (baseVersion !== undefined && row.version !== baseVersion) {
      return { conflict: true as const, transcript: mapTranscript(row) };
    }
    const now = Date.now();
    await db.run(
      `UPDATE message_transcripts SET status = 'completed', corrected_text = ?, corrected_by_account_id = ?,
       corrected_at = ?, last_error = NULL, version = version + 1, updated_at = ? WHERE message_id = ?`,
      [text, identity.accountId, now, now, messageId],
    );
    await db.run(
      `UPDATE transcript_jobs SET status = 'completed', lease_until = NULL, last_error = NULL,
       completed_at = ?, updated_at = ? WHERE message_id = ?`,
      [now, now, messageId],
    );
    const updated = await db.get<TranscriptRow>("SELECT * FROM message_transcripts WHERE message_id = ?", [messageId]);
    await appendSyncEvent(db, {
      coupleId: row.couple_id,
      accountId: row.owner_account_id,
      entityType: "message_transcript",
      entityId: messageId,
      operation: "upsert",
      payload: updated ? mapTranscript(updated) : { messageId },
      actorAccountId: identity.accountId,
      actorDeviceId: user.deviceId,
      createdAt: now,
    });
    return { conflict: false as const, transcript: updated ? mapTranscript(updated) : null };
  });
}

async function claimJob(provider: TranscriptionProvider): Promise<ClaimedJob | null> {
  return transaction(async (db) => {
    const now = Date.now();
    const job = await db.get<{
      id: string;
      message_id: string;
      attempt_count: number;
      path: string;
      mime_type: string;
    }>(
      `SELECT job.id, job.message_id, job.attempt_count, upload.path, upload.mime_type
         FROM transcript_jobs job
         JOIN uploads upload ON upload.message_id = job.message_id
        WHERE ((job.status IN ('queued', 'failed') AND job.available_at <= ?)
          OR (job.status = 'processing' AND job.lease_until < ?))
        ORDER BY job.available_at ASC, job.created_at ASC
        LIMIT 1 FOR UPDATE OF job SKIP LOCKED`,
      [now, now],
    );
    if (!job) return null;
    await db.run(
      `UPDATE transcript_jobs SET status = 'processing', provider = ?, attempt_count = attempt_count + 1,
       lease_until = ?, updated_at = ? WHERE id = ?`,
      [provider.name, now + 5 * 60_000, now, job.id],
    );
    await db.run(
      `UPDATE message_transcripts SET status = 'processing', provider = ?, last_error = NULL,
       version = version + 1, updated_at = ? WHERE message_id = ?`,
      [provider.name, now, job.message_id],
    );
    return {
      jobId: job.id,
      messageId: job.message_id,
      path: job.path,
      mimeType: job.mime_type,
      attemptCount: job.attempt_count + 1,
    };
  });
}

export async function runTranscriptWorkerOnce(provider: TranscriptionProvider): Promise<boolean> {
  const job = await claimJob(provider);
  if (!job) return false;
  try {
    const result = await provider.transcribe({ messageId: job.messageId, path: job.path, mimeType: job.mimeType });
    const text = result.text.trim();
    if (!text) throw new Error("empty_transcript");
    await transaction(async (db) => {
      const now = Date.now();
      await db.run(
        `UPDATE message_transcripts SET status = 'completed', text = ?, language = ?, provider = ?,
         last_error = NULL, version = version + 1, updated_at = ? WHERE message_id = ?`,
        [text, result.language ?? null, provider.name, now, job.messageId],
      );
      await db.run(
        `UPDATE transcript_jobs SET status = 'completed', lease_until = NULL, last_error = NULL,
         completed_at = ?, updated_at = ? WHERE id = ?`,
        [now, now, job.jobId],
      );
      const row = await db.get<TranscriptRow & { couple_id: string | null; owner_account_id: string | null }>(
        "SELECT * FROM message_transcripts WHERE message_id = ?",
        [job.messageId],
      );
      if (row) await appendSyncEvent(db, {
        coupleId: row.couple_id,
        accountId: row.owner_account_id,
        entityType: "message_transcript",
        entityId: job.messageId,
        operation: "upsert",
        payload: mapTranscript(row),
        createdAt: now,
      });
    });
  } catch (error) {
    const message = error instanceof Error ? error.message.slice(0, 500) : String(error).slice(0, 500);
    await transaction(async (db) => {
      const now = Date.now();
      const delay = Math.min(60_000 * 2 ** Math.min(job.attemptCount, 6), 60 * 60_000);
      await db.run(
        `UPDATE message_transcripts SET status = 'failed', last_error = ?,
         version = version + 1, updated_at = ? WHERE message_id = ?`,
        [message, now, job.messageId],
      );
      await db.run(
        `UPDATE transcript_jobs SET status = 'failed', lease_until = NULL, last_error = ?,
         available_at = ?, updated_at = ? WHERE id = ?`,
        [message, now + delay, now, job.jobId],
      );
      const row = await db.get<TranscriptRow & { couple_id: string | null; owner_account_id: string | null }>(
        "SELECT * FROM message_transcripts WHERE message_id = ?",
        [job.messageId],
      );
      if (row) await appendSyncEvent(db, {
        coupleId: row.couple_id,
        accountId: row.owner_account_id,
        entityType: "message_transcript",
        entityId: job.messageId,
        operation: "upsert",
        payload: mapTranscript(row),
        createdAt: now,
      });
    });
  }
  return true;
}
