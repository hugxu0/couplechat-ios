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
    conversation?: {
      continued: boolean;
      turnCount: number;
    };
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

/** 删除由某条消息触发的本机调试 trace，避免撤回后日志仍保留完整问题/prompt。 */
export async function redactTraceForMessage(messageId: string): Promise<void> {
  liveTraces.delete(messageId);
  const dir = path.join(config.dataDir, "ai_logs");
  let names: string[];
  try {
    names = await fs.promises.readdir(dir);
  } catch {
    return;
  }
  await Promise.all(names.filter((name) => name.endsWith(".log")).map(async (name) => {
    const file = path.join(dir, name);
    try {
      const raw = await fs.promises.readFile(file, "utf8");
      const parts = raw.split(`\n${BANNER}\n`);
      const marker = `\"id\": \"${messageId.replace(/[\\\"]/g, "\\$&")}\"`;
      const filtered = parts.filter((part, index) => index === 0 || !part.includes(marker));
      if (filtered.length === parts.length) return;
      const next = filtered[0] + filtered.slice(1).map((part) => `\n${BANNER}\n${part}`).join("");
      const temporary = `${file}.${process.pid}.partial`;
      await fs.promises.writeFile(temporary, next, { mode: 0o600 });
      await fs.promises.rename(temporary, file);
    } catch (error) {
      console.warn(`[ai-trace] 撤回清理失败 id=${messageId}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }));
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
