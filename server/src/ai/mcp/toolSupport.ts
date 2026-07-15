import type { MessageRow } from "../../db";
import { accounts } from "../accounts";
import type { MemoryItem } from "../memory/store";
import { beijingDateTime } from "../time";
import type { AgentToolRun } from "./runContext";

export function jsonResult(value: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(value) }] };
}

export function allowedChannels(run: AgentToolRun): string[] {
  return run.identity.storedChannel.startsWith("ai:")
    ? ["couple", run.identity.storedChannel]
    : ["couple"];
}

export function safeLimit(value: number | undefined, fallback = 10, max = 30): number {
  return Math.max(1, Math.min(max, Math.round(value ?? fallback)));
}

export function parseTime(value: string | undefined): number | null {
  if (!value) return null;
  const beijingDate = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value.trim());
  if (beijingDate) {
    const year = Number(beijingDate[1]);
    const month = Number(beijingDate[2]);
    const day = Number(beijingDate[3]);
    const utc = Date.UTC(year, month - 1, day) - 8 * 60 * 60 * 1000;
    const check = new Date(utc + 8 * 60 * 60 * 1000);
    if (check.getUTCFullYear() !== year || check.getUTCMonth() !== month - 1 || check.getUTCDate() !== day) {
      return null;
    }
    return utc;
  }
  const number = Number(value);
  if (Number.isFinite(number) && number > 0) return number;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function messageView(row: MessageRow, details?: { matchedTerms?: string[]; relevance?: number }) {
  return {
    id: row.id,
    channel: row.channel,
    sender: row.sender,
    senderName: row.sender_name,
    type: row.type,
    text: row.text.slice(0, 1200),
    url: row.url,
    ts: row.ts,
    time: beijingDateTime(row.ts),
    isOwnerEvidence: row.sender !== "ai",
    ...(details?.matchedTerms ? { matchedTerms: details.matchedTerms } : {}),
    ...(details?.relevance !== undefined ? { relevance: Number(details.relevance.toFixed(3)) } : {}),
  };
}

export function memoryView(item: MemoryItem & { score?: number; lexicalHits?: number }) {
  const names = accounts();
  const subjectNames = item.subjects.includes("both")
    ? names.map((account) => account.name)
    : item.subjects.map((subject) => names.find((account) => account.username === subject)?.name ?? subject);
  return {
    id: item.id,
    layer: item.layer,
    perspective: item.perspective,
    kind: item.kind,
    subjects: item.subjects,
    subjectNames,
    content: item.content,
    category: item.category,
    confidence: item.confidence,
    importance: item.importance,
    occurredAt: item.occurredAt,
    occurredTime: item.occurredAt ? beijingDateTime(item.occurredAt) : null,
    occurredEndAt: item.occurredEndAt,
    occurredEndTime: item.occurredEndAt ? beijingDateTime(item.occurredEndAt) : null,
    memoryValidFrom: item.validFrom,
    memoryValidFromTime: item.validFrom ? beijingDateTime(item.validFrom) : null,
    memoryValidUntil: item.validUntil,
    memoryValidUntilTime: item.validUntil ? beijingDateTime(item.validUntil) : null,
    updatedAt: item.updatedAt,
    updatedTime: beijingDateTime(item.updatedAt),
    score: item.score ?? 0,
    lexicalHits: item.lexicalHits ?? 0,
  };
}
