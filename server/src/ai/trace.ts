// 应答全链路 Trace 日志：每轮 respond() 创建一个 trace，各步往里堆，
// finally 时 flush 到 .data/ai_logs/reply-trace-YYYY-MM-DD.log（append）。
// 排查「这轮回复为什么这么答/为什么没记忆」时直接看这个文件。

import fs from "node:fs";
import path from "node:path";
import { config } from "../config";
import type { PlanContext } from "./intent";
import type { LogMessage } from "./chatLog";

export interface TraceEntry {
  ts: number;
  channel: string;
  requesterName: string;
  question: string;
  intent?: PlanContext;
  retrievalPlan?: { retrievalQuery: string; resolvedQuestion: string };
  retrieval?: {
    query: string;
    rawFacts: { id: string; subject: string; text: string; score: number }[];
    rawEpisodes: { id: string; title: string; date: string; score: number }[];
    factMinScore: number;
    episodeMinScore: number;
  };
  context?: {
    profileCards: string;
    mood: string;
    shortMemory: string;
    factsContext: string;
    episodesContext: string;
    imageContext: string;
    searchContext: string;
    tasksText: string;
    sessionSummary: string;
    recentEarlier: string;
    recentImmediate: string;
  };
  reply?: {
    stage: string;
    usedVision: boolean;
    wantsSearch: boolean;
    replies: string[];
    actions: unknown[];
  };
  conflict?: {
    conflict: boolean;
    confidence: number;
    reason: string;
    reply: string;
  };
  interject?: {
    shouldReply: boolean;
    reply: string;
  };
  error?: string;
}

export function traceBegin(channel: string, requesterName: string, question: string): TraceEntry {
  return { ts: Date.now(), channel, requesterName, question };
}

export function traceIntent(trace: TraceEntry, plan: PlanContext) {
  trace.intent = plan;
}

export function traceRetrievalPlan(trace: TraceEntry, plan: { retrievalQuery: string; resolvedQuestion: string }) {
  trace.retrievalPlan = plan;
}

export function traceRetrieval(
  trace: TraceEntry,
  data: {
    query: string;
    rawFacts: { id: string; subject: string; text: string; score: number }[];
    rawEpisodes: { id: string; title: string; date: string; score: number }[];
    factMinScore: number;
    episodeMinScore: number;
  },
) {
  trace.retrieval = data;
}

export function traceContext(trace: TraceEntry, data: NonNullable<TraceEntry["context"]>) {
  trace.context = data;
}

export function traceReply(
  trace: TraceEntry,
  data: { stage: string; usedVision: boolean; wantsSearch: boolean; replies: string[]; actions: unknown[] },
) {
  trace.reply = data;
}

export function traceConflict(
  trace: TraceEntry,
  data: { conflict: boolean; confidence: number; reason: string; reply: string },
) {
  trace.conflict = data;
}

export function traceInterject(trace: TraceEntry, data: { shouldReply: boolean; reply: string }) {
  trace.interject = data;
}

export function traceError(trace: TraceEntry, message: string) {
  trace.error = message;
}

const BANNER = "─".repeat(72);

export function traceFlush(trace: TraceEntry): void {
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
  } catch {
    // 日志写失败不影响主流程
  }
}