// 每轮 Agent 应答写入一条本机 Trace，包含 Prompt、工具调用和最终输出。

import fs from "node:fs";
import path from "node:path";
import { nanoid } from "nanoid";
import { config } from "../../config";

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
    finalOutput?: string;
    fallbackReason?: string;
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

export function tracePrompt(trace: TraceEntry, system: string, user: string) {
  trace.prompt = { system, user };
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

export function traceReply(
  trace: TraceEntry,
    data: { stage: string; usedVision: boolean; wantsSearch: boolean; replies: string[]; actions: unknown[]; rawOutput?: string },
) {
  trace.reply = data;
}

export function traceError(trace: TraceEntry, message: string) {
  trace.error = message;
}

const BANNER = "─".repeat(72);

export function traceFlush(trace: TraceEntry): void {
  trace.status = "completed";
  trace.finishedTs = Date.now();
  trace.timings = trace.timings ?? {};
  trace.timings.total = trace.finishedTs - trace.ts;
  try {
    const dir = path.join(config.dataDir, "ai_logs");
    fs.mkdirSync(dir, { recursive: true });
    const d = new Date(trace.ts);
    const pad = (n: number) => String(n).padStart(2, "0");
    const dateStr = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
    const file = path.join(dir, `reply-trace-${dateStr}.log`);
    const header = `\n${BANNER}\n[${new Date(trace.ts).toISOString()}] channel=${trace.channel} requester=${trace.requesterName}\nquestion: ${trace.question}\n`;
    const body = JSON.stringify(trace, null, 2);
    fs.appendFileSync(file, header + body + "\n");
  } catch {}
}
