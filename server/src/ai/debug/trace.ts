// Trace 只保留在当前非生产调试进程的内存中，不写入磁盘。

import { nanoid } from "nanoid";

export interface TraceEntry {
  id: string;
  ts: number;
  status: "running" | "completed";
  finishedTs?: number;
  channel: string;
  requesterName: string;
  question: string;
  agent?: {
    enabled: boolean;
    model: string;
    turns?: number;
    toolCalls: Array<{
      name: string;
      args: unknown;
      startedAt: number;
      durationMs: number;
      result: string;
      error: string;
    }>;
    conversation?: {
      continued: boolean;
      turnCount: number;
    };
    finalOutput?: string;
  };
  reply?: {
    stage: string;
    usedVision: boolean;
    wantsSearch: boolean;
    replies: string[];
    actions: unknown[];
    rawOutput?: string;
  };
  prompt?: { system: string; user: string };
  timings?: Record<string, number>;
  error?: string;
}

const liveTraces = new Map<string, TraceEntry>();
const MAX_LIVE_TRACES = 100;

export function traceBegin(channel: string, requesterName: string, question: string, id?: string): TraceEntry {
  const trace: TraceEntry = {
    id: id || nanoid(12),
    ts: Date.now(),
    status: "running",
    channel,
    requesterName,
    question,
    timings: {},
  };
  liveTraces.set(trace.id, trace);
  while (liveTraces.size > MAX_LIVE_TRACES) {
    const oldest = liveTraces.keys().next().value as string | undefined;
    if (!oldest) break;
    liveTraces.delete(oldest);
  }
  return trace;
}

export function traceTiming(trace: TraceEntry, stage: string, startedAt: number) {
  trace.timings = trace.timings ?? {};
  trace.timings[stage] = Date.now() - startedAt;
}

export function getLiveTrace(id: string): TraceEntry | null {
  return liveTraces.get(id) ?? null;
}

export function listLiveTraces(since = 0): TraceEntry[] {
  return [...liveTraces.values()].filter((trace) => trace.ts >= since).sort((a, b) => b.ts - a.ts);
}

/** 删除由某条消息触发的内存调试 trace。 */
export async function redactTraceForMessage(messageId: string): Promise<void> {
  liveTraces.delete(messageId);
}

export function traceReply(
  trace: TraceEntry,
    data: { stage: string; usedVision: boolean; wantsSearch: boolean; replies: string[]; actions: unknown[]; rawOutput?: string },
) {
  trace.reply = data;
}

export function traceError(trace: TraceEntry, message: string) {
  trace.error = message;
}

export function traceFlush(trace: TraceEntry): void {
  trace.status = "completed";
  trace.finishedTs = Date.now();
  trace.timings = trace.timings ?? {};
  trace.timings.total = trace.finishedTs - trace.ts;
}
