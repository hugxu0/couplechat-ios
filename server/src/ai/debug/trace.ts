// Trace 只保留在当前进程内存中，不写入磁盘。
// 生产环境只保留元数据，不写完整 prompt / 工具结果 / 私聊正文。

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

function redactQuestion(question: string): string {
  if (!config.isProduction) return question;
  const trimmed = question.trim();
  if (!trimmed) return "";
  return `[redacted len=${trimmed.length}]`;
}

export function traceBegin(channel: string, requesterName: string, question: string, id?: string): TraceEntry {
  const trace: TraceEntry = {
    id: id || nanoid(12),
    ts: Date.now(),
    status: "running",
    channel,
    requesterName,
    question: redactQuestion(question),
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
  data: {
    stage: string;
    usedVision: boolean;
    wantsSearch: boolean;
    replies: string[];
    actions: unknown[];
    rawOutput?: string;
  },
) {
  if (config.isProduction) {
    trace.reply = {
      stage: data.stage,
      usedVision: data.usedVision,
      wantsSearch: data.wantsSearch,
      replies: data.replies.map((text) => `[redacted len=${text.length}]`),
      actions: data.actions.map((action) =>
        typeof action === "object" && action !== null
          ? { type: (action as { type?: string }).type ?? "action" }
          : "action",
      ),
    };
    return;
  }
  trace.reply = data;
}

export function traceError(trace: TraceEntry, message: string) {
  trace.error = message;
}

export function tracePrompt(trace: TraceEntry, prompt: { system: string; user: string }): void {
  if (config.isProduction) {
    trace.prompt = {
      system: `[redacted len=${prompt.system.length}]`,
      user: `[redacted len=${prompt.user.length}]`,
    };
    return;
  }
  trace.prompt = prompt;
}

export function traceFlush(trace: TraceEntry): void {
  trace.status = "completed";
  trace.finishedTs = Date.now();
  trace.timings = trace.timings ?? {};
  trace.timings.total = trace.finishedTs - trace.ts;
  if (config.isProduction) {
    // 生产不保留工具正文与模型全文。
    if (trace.agent?.toolCalls) {
      trace.agent = {
        ...trace.agent,
        toolCalls: trace.agent.toolCalls.map((call) => ({
          name: call.name,
          args: {},
          startedAt: call.startedAt,
          durationMs: call.durationMs,
          result: call.result ? `[redacted len=${call.result.length}]` : "",
          error: call.error ? call.error.slice(0, 200) : "",
        })),
        finalOutput: trace.agent.finalOutput
          ? `[redacted len=${trace.agent.finalOutput.length}]`
          : undefined,
      };
    }
  }
}
