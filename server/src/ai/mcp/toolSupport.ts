import type { MessageRow } from "../../db";
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

export function memoryView(item: MemoryItem & { score?: number; lexicalHits?: number; evidenceCount?: number }) {
  return {
    id: item.id,
    layer: item.layer,
    subjects: item.subjects,
    content: item.content,
    category: item.category,
    confidence: item.confidence,
    importance: item.importance,
    occurredAt: item.occurredAt,
    occurredTime: item.occurredAt ? beijingDateTime(item.occurredAt) : null,
    validFrom: item.validFrom,
    validUntil: item.validUntil,
    metadata: item.metadata,
    score: item.score ?? 0,
    lexicalHits: item.lexicalHits ?? 0,
    evidenceCount: item.evidenceCount ?? 0,
  };
}
