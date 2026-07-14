import { createHmac, timingSafeEqual } from "node:crypto";
import { config } from "../../config";
import type { AiAction } from "../actions/personalItems";
import type { Citation } from "../provider";
import type { TraceEntry } from "../debug/trace";

export interface AgentRunIdentity {
  traceId: string;
  messageId?: string;
  requesterUsername: string;
  requesterName: string;
  storedChannel: string;
  currentImageUrl?: string;
  expiresAt: number;
}

export interface AgentToolRun {
  identity: AgentRunIdentity;
  trace: TraceEntry;
  actions: AiAction[];
  citations: Citation[];
  usedVision: boolean;
  toolCounts: Record<string, number>;
}

const activeRuns = new Map<string, AgentToolRun>();

function encode(value: string): string {
  return Buffer.from(value, "utf8").toString("base64url");
}

function signature(payload: string): string {
  return createHmac("sha256", config.tokenSecret).update(payload).digest("base64url");
}

export function beginAgentToolRun(
  identity: Omit<AgentRunIdentity, "expiresAt">,
  trace: TraceEntry,
): { run: AgentToolRun; token: string } {
  const full: AgentRunIdentity = { ...identity, expiresAt: Date.now() + 5 * 60_000 };
  const run: AgentToolRun = {
    identity: full,
    trace,
    actions: [],
    citations: [],
    usedVision: false,
    toolCounts: {},
  };
  activeRuns.set(full.traceId, run);
  const payload = encode(JSON.stringify(full));
  return { run, token: `${payload}.${signature(payload)}` };
}

export function resolveAgentToolRun(token: string | undefined): AgentToolRun | null {
  if (!token) return null;
  const [payload, supplied] = token.split(".");
  if (!payload || !supplied) return null;
  const expected = signature(payload);
  const a = Buffer.from(supplied);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  try {
    const identity = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as AgentRunIdentity;
    if (!identity.traceId || identity.expiresAt < Date.now()) return null;
    const run = activeRuns.get(identity.traceId);
    if (!run || run.identity.requesterUsername !== identity.requesterUsername) return null;
    return run;
  } catch {
    return null;
  }
}

export function endAgentToolRun(traceId: string): void {
  activeRuns.delete(traceId);
}

export async function recordAgentTool<T>(
  run: AgentToolRun,
  name: string,
  args: unknown,
  work: () => Promise<T>,
): Promise<T> {
  const nextCount = (run.toolCounts[name] ?? 0) + 1;
  run.toolCounts[name] = nextCount;
  const perToolLimits: Record<string, number> = {
    search_facts: 1,
    search_events: 2,
    search_plans: 2,
    search_chat_messages: 2,
    get_messages_around: 2,
    get_memory_evidence: 2,
    web_search: 2,
    inspect_recent_image: 1,
    list_personal_items: 2,
    draft_personal_item_action: 6,
  };
  const totalCalls = Object.values(run.toolCounts).reduce((sum, count) => sum + count, 0);
  const limit = perToolLimits[name] ?? 2;
  if (nextCount > limit || totalCalls > 12) {
    throw new Error("本轮检索预算已用完。请停止调用工具，根据已有可靠证据回答；证据不足就明确说无法确认。 ");
  }
  const startedAt = Date.now();
  const entry = { name, args, startedAt, durationMs: 0, result: "", error: "" };
  run.trace.agent = run.trace.agent ?? { enabled: true, model: "", toolCalls: [] };
  run.trace.agent.toolCalls.push(entry);
  try {
    const result = await work();
    entry.result = JSON.stringify(result).slice(0, 12_000);
    return result;
  } catch (error) {
    entry.error = error instanceof Error ? error.message : String(error);
    throw error;
  } finally {
    entry.durationMs = Date.now() - startedAt;
  }
}
