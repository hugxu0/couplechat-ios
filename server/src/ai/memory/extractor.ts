import { accounts } from "../accounts";
import { ownerTextMessagesAfter, type LogMessage } from "../conversation/log";
import { chat, extractJson } from "../provider";
import { GEN } from "../settings";
import { beijingDateTime } from "../time";
import { refreshDerivedMemory } from "./derived";
import {
  addMemory,
  advanceMemoryCursor,
  archiveSiblingMemories,
  initializeMemoryCursor,
  listActiveMemoryContext,
  memoryCursor,
  normalizedMemorySubjects,
  reconcileMemoryLifecycle,
  transitionMemory,
  type MemoryCandidate,
  type MemoryItem,
  type MemoryLayer,
} from "./store";

interface ExtractedMemory {
  operation?: "upsert" | "append" | "retract" | "complete" | "cancel";
  targetMemoryId?: string;
  layer?: string;
  memoryKey?: string;
  subjects?: string[];
  content?: string;
  category?: string;
  confidence?: number;
  importance?: number;
  sourceMessageIds?: string[];
  occurredMessageId?: string;
  validHours?: number;
  metadata?: Record<string, unknown>;
  reason?: string;
}

interface ExtractedEngagement {
  kind?: "none" | "conflict" | "interject";
  confidence?: number;
  reason?: string;
}

export interface MemoryEngagementSignal {
  channel: string;
  kind: "conflict" | "interject";
  confidence: number;
  reason: string;
  requesterUsername: string;
  requesterName: string;
  context: string;
}

let engagementHandler: ((signal: MemoryEngagementSignal) => void | Promise<void>) | null = null;

export function setMemoryEngagementHandler(
  handler: ((signal: MemoryEngagementSignal) => void | Promise<void>) | null,
): void {
  engagementHandler = handler;
}

const scanTimers = new Map<string, NodeJS.Timeout>();
const planningTimers = new Map<string, NodeJS.Timeout>();
const running = new Set<string>();
const retryAttempts = new Map<string, number>();

export const MEMORY_SOURCE_BATCH_SIZE = 80;
export const MEMORY_BUSY_BATCH_THRESHOLD = 20;
export const MEMORY_BUSY_IDLE_MS = 15 * 60 * 1000;
export const MEMORY_QUIET_IDLE_MS = 60 * 60 * 1000;
export const MEMORY_MAX_BATCH_AGE_MS = 2 * 60 * 60 * 1000;

export function memoryExtractionDelay(
  sourceMessageCount: number,
  oldestMessageAt: number,
  newestMessageAt: number,
  now = Date.now(),
  force = false,
): number | null {
  if (sourceMessageCount <= 0) return null;
  if (force || sourceMessageCount >= MEMORY_SOURCE_BATCH_SIZE) return 0;
  const idleWindow = sourceMessageCount >= MEMORY_BUSY_BATCH_THRESHOLD
    ? MEMORY_BUSY_IDLE_MS
    : MEMORY_QUIET_IDLE_MS;
  const dueAt = Math.min(newestMessageAt + idleWindow, oldestMessageAt + MEMORY_MAX_BATCH_AGE_MS);
  return Math.max(0, dueAt - now);
}

export function shouldExtractMemoryBatch(
  sourceMessageCount: number,
  force = false,
  dueDelay = Number.POSITIVE_INFINITY,
): boolean {
  return sourceMessageCount > 0
    && (force || sourceMessageCount >= MEMORY_SOURCE_BATCH_SIZE || dueDelay <= 0);
}

function systemPrompt(includeEngagement: boolean): string {
  const people = accounts().map((account) => `${account.username}=${account.name}`).join("、");
  return [
    "你是 CoupleChat 的基础记忆整理器。输入包含当前有效基础记忆和一段连续聊天；只提取事实、经历、计划、近况四类。关系与理解由另一阶段根据这些卡片生成，本阶段禁止输出 relationship/insight。",
    `人物 username：${people}。subjects 必须且只能是单个逻辑主体：xu、si 或 both。`,
    "subjects 表示内容是谁的，不表示谁说了这句话，也不表示卡片是否双方可见。只属于小旭的事情用 xu，只属于小偲的事情用 si；只有两个人共同参与、共同承担或整体状态才用 both。双方只是讨论某一个人的事，仍归这个人。",
    "fact：稳定、将来可直接查询的个人或共同事实，例如身份、偏好、习惯、健康禁忌和重要人物。事实应原子化。",
    "event：值得以后回忆或检索的一次经历。只存有意义的记录，不把每个生活碎片都变成事件。内容约 50~120 个汉字，必须独立讲清人物、时间线索、事情和结果，便于脱离原文进行向量检索。",
    "plan：未来安排、承诺和准备做的事。按实际执行者归属；只有两个人都要执行才用 both。必须给 validHours，未明确期限默认 720 小时。",
    "state：近三天的滚动近况，可以事无巨细地记录有用细节，包括上午/下午做了什么、健康与情绪、讨论主题、双方观点和意见不同。每个主体本批最多一张，内容尽量 300~800 字，必须给 validHours，默认 72 小时。",
    "operation：upsert 新增/更新 fact、plan、state；append 追加 event；retract 表示明确否定旧记忆；complete/cancel 只用于计划。",
    "更新、否定、完成或取消已有事实/计划时，使用输入中的 targetMemoryId 并复用 memoryKey；近况由代码按主体维护固定滚动键，不必引用旧近况 id。",
    "每条变更必须引用本批真实 sourceMessageIds。occurredMessageId 指向最能代表发生时间的消息；不得编造日期。",
    "连续的同一次经历合成一张 event；近况中的琐碎活动不要再重复生成 event，除非它具有长期回忆或检索价值。",
    "confidence 0~1，importance 1~5。玩笑、问句、AI 回复、未确认猜测、辱骂中的人格判断均不保存。",
    ...(includeEngagement ? [
      "同时判断公聊 engagement，但不要回复用户：明显冲突才用 conflict；无冲突但确有情侣专属价值可补充时用 interject；普通闲聊用 none。",
      '只输出 JSON：{"changes":[{"operation":"upsert","layer":"fact","memoryKey":"fact.xu.preference","subjects":["xu"],"content":"...","sourceMessageIds":["msg_x"],"occurredMessageId":"msg_x","validHours":72}],"engagement":{"kind":"none","confidence":0,"reason":""}}',
    ] : [
      '只输出 JSON：{"changes":[{"operation":"upsert","layer":"fact","memoryKey":"fact.xu.preference","subjects":["xu"],"content":"...","sourceMessageIds":["msg_x"],"occurredMessageId":"msg_x","validHours":72}]}',
    ]),
    "changes 最多 40 条。没有变更时 changes 为空数组。",
  ].join("\n");
}

function messageLine(message: LogMessage): string {
  const body = message.type === "text" ? message.text.replace(/\s+/g, " ").trim() : `[${message.type}]`;
  return `[${message.id}] [${beijingDateTime(message.ts)}] [${message.sender}/${message.senderName}] ${body.slice(0, 1000)}`;
}

function memoryContextLine(memory: MemoryItem): string {
  return `[${memory.id}] layer=${memory.layer} key=${memory.memoryKey} subject=${memory.subjects[0] ?? "unknown"} content=${memory.content.slice(0, 700)}`;
}

export function minimumEvidenceForLayer(_layer: MemoryLayer): number {
  return 1;
}

const BASE_MEMORY_LAYERS = new Set<MemoryLayer>(["fact", "event", "plan", "state"]);

async function scanChannel(channel: string, force = false): Promise<void> {
  if (running.has(channel)) return;
  running.add(channel);
  try {
    const cursor = await memoryCursor(channel);
    if (!cursor.ts) {
      await initializeMemoryCursor(channel);
      return;
    }
    const sourceMessages = await ownerTextMessagesAfter(channel, cursor, MEMORY_SOURCE_BATCH_SIZE);
    if (!sourceMessages.length) return;
    const dueDelay = memoryExtractionDelay(
      sourceMessages.length,
      sourceMessages[0].ts,
      sourceMessages.at(-1)!.ts,
    ) ?? Number.POSITIVE_INFINITY;
    if (!shouldExtractMemoryBatch(sourceMessages.length, force, dueDelay)) {
      scheduleMemoryScan(channel, dueDelay);
      return;
    }

    const nextCursor = { ts: sourceMessages.at(-1)!.ts, id: sourceMessages.at(-1)!.id };
    const sourceById = new Map(sourceMessages.map((message) => [message.id, message]));
    const activeMemories = (await listActiveMemoryContext(channel, 180))
      .filter((memory) => BASE_MEMORY_LAYERS.has(memory.layer));
    const activeById = new Map(activeMemories.map((memory) => [memory.id, memory]));
    const output = await chat({
      profile: "task",
      system: systemPrompt(channel === "couple"),
      user: [
        `【当前有效基础记忆，频道=${channel}】\n${activeMemories.map(memoryContextLine).join("\n") || "（空）"}`,
        `【本批新消息】\n${sourceMessages.map(messageLine).join("\n")}`,
      ].join("\n\n"),
      gen: GEN.extractFacts,
    });
    if (!output) throw new Error("基础记忆模型无输出");
    const parsed = extractJson<{ changes?: ExtractedMemory[]; engagement?: ExtractedEngagement }>(output);
    if (!parsed || !Array.isArray(parsed.changes)) throw new Error("基础记忆 JSON 无效");

    let saved = 0;
    const stateSubjects = new Set<string>();
    for (const item of parsed.changes.slice(0, 40)) {
      const sourceIds = [...new Set(item.sourceMessageIds ?? [])].filter((id) => sourceById.has(id));
      if (!sourceIds.length) continue;
      const operation = item.operation ?? "upsert";
      const target = item.targetMemoryId ? activeById.get(item.targetMemoryId) : undefined;
      if (["retract", "complete", "cancel"].includes(operation)) {
        if (!target) continue;
        if ((operation === "complete" || operation === "cancel") && target.layer !== "plan") continue;
        const status = operation === "complete" ? "completed" : operation === "cancel" ? "cancelled" : "retracted";
        if (await transitionMemory({
          memoryId: target.id,
          scope: channel,
          status,
          sourceMessageIds: sourceIds,
          reason: item.reason,
        })) saved += 1;
        continue;
      }

      if (!item.content || !item.layer || !BASE_MEMORY_LAYERS.has(item.layer as MemoryLayer)) continue;
      const subjects = normalizedMemorySubjects(item.subjects ?? []);
      if (subjects.length !== 1) continue;
      const subject = subjects[0];
      const layer = item.layer as MemoryLayer;
      if (target && target.layer !== layer) continue;
      if (layer === "state" && stateSubjects.has(subject)) continue;
      if (layer !== "state" && !item.memoryKey) continue;
      if (layer === "state") stateSubjects.add(subject);

      const occurredMessage = item.occurredMessageId ? sourceById.get(item.occurredMessageId) : undefined;
      const lastEvidence = sourceById.get(sourceIds.at(-1)!);
      const baseTime = occurredMessage?.ts ?? lastEvidence?.ts ?? Date.now();
      const suppliedValidHours = Number(item.validHours);
      const validHours = Number.isFinite(suppliedValidHours) && suppliedValidHours > 0
        ? Math.min(24 * 365, suppliedValidHours)
        : layer === "state" ? 72 : layer === "plan" ? 24 * 30 : null;
      const targetForUpdate = layer === "state" ? undefined : target;
      const candidate: MemoryCandidate = {
        layer,
        scope: channel,
        memoryKey: layer === "state"
          ? `state.${subject}.recent`
          : targetForUpdate?.memoryKey ?? item.memoryKey!,
        subjects,
        speakers: [...new Set(sourceIds.map((id) => sourceById.get(id)!.sender))],
        content: item.content,
        category: item.category,
        confidence: item.confidence,
        importance: item.importance,
        occurredAt: layer === "event" ? baseTime : null,
        validFrom: layer !== "event" ? baseTime : null,
        validUntil: validHours && (layer === "state" || layer === "plan")
          ? baseTime + validHours * 60 * 60 * 1000
          : null,
        metadata: { ...item.metadata, updateReason: item.reason ?? "", extractorVersion: 3 },
        sourceMessageIds: sourceIds,
        targetMemoryId: targetForUpdate?.id,
      };
      const stored = await addMemory(candidate);
      if (stored) {
        saved += 1;
        if (layer === "state") await archiveSiblingMemories(stored.id, true);
      }
    }

    await advanceMemoryCursor(channel, nextCursor);
    await reconcileMemoryLifecycle();
    const engagement = parsed.engagement;
    const kind = engagement?.kind;
    const confidence = Math.max(0, Math.min(1, Number(engagement?.confidence) || 0));
    await refreshDerivedMemory(channel, { forceRelationship: kind === "conflict" && confidence >= 0.7 });
    const threshold = kind === "conflict" ? 0.7 : 0.78;
    if (channel === "couple" && engagementHandler
      && (kind === "conflict" || kind === "interject") && confidence >= threshold) {
      const requester = sourceMessages.at(-1)!;
      const signal: MemoryEngagementSignal = {
        channel,
        kind,
        confidence,
        reason: String(engagement?.reason ?? "").replace(/\s+/g, " ").trim().slice(0, 600),
        requesterUsername: requester.sender,
        requesterName: requester.senderName,
        context: sourceMessages.map(messageLine).join("\n"),
      };
      void Promise.resolve(engagementHandler(signal)).catch((error) => {
        console.warn("[memory] 后台介入信号处理失败:", error instanceof Error ? error.message : error);
      });
    }
    console.log(`[memory] ${channel} 整理 ${sourceMessages.length} 条消息，写入/更新 ${saved} 条基础记忆`);
  } finally {
    running.delete(channel);
  }
}

async function planMemoryScan(channel: string): Promise<void> {
  if (running.has(channel)) return;
  const cursor = await memoryCursor(channel);
  if (!cursor.ts) return;
  const sourceMessages = await ownerTextMessagesAfter(channel, cursor, MEMORY_SOURCE_BATCH_SIZE);
  const existing = scanTimers.get(channel);
  if (existing) clearTimeout(existing);
  scanTimers.delete(channel);
  if (!sourceMessages.length) return;
  const delay = memoryExtractionDelay(
    sourceMessages.length,
    sourceMessages[0].ts,
    sourceMessages.at(-1)!.ts,
  );
  if (delay !== null) scheduleMemoryScan(channel, delay);
}

function schedulePlanning(channel: string): void {
  const existing = planningTimers.get(channel);
  if (existing) clearTimeout(existing);
  planningTimers.set(channel, setTimeout(() => {
    planningTimers.delete(channel);
    void planMemoryScan(channel).catch((error) => {
      console.warn(`[memory] ${channel} 规划整理失败:`, error instanceof Error ? error.message : error);
    });
  }, 250));
}

function scheduleMemoryScan(channel: string, delayMs: number): void {
  const existing = scanTimers.get(channel);
  if (existing) clearTimeout(existing);
  scanTimers.set(channel, setTimeout(() => {
    scanTimers.delete(channel);
    void scanChannel(channel)
      .then(() => {
        retryAttempts.delete(channel);
        schedulePlanning(channel);
      })
      .catch((error) => {
        const attempt = (retryAttempts.get(channel) ?? 0) + 1;
        retryAttempts.set(channel, attempt);
        const retryDelay = Math.min(5 * 60_000, 30_000 * 2 ** Math.min(4, attempt - 1));
        console.warn(
          `[memory] ${channel} 提取失败，${Math.round(retryDelay / 1000)}s 后重试:`,
          error instanceof Error ? error.message : error,
        );
        scheduleMemoryScan(channel, retryDelay);
      });
  }, Math.max(0, delayMs)));
}

export async function initializeMemory(): Promise<void> {
  const channels = ["couple", ...accounts().map((account) => `ai:${account.username}`)];
  await Promise.all(channels.map((channel) => initializeMemoryCursor(channel)));
  channels.forEach(schedulePlanning);
  console.log(`[memory] 已初始化 ${channels.length} 个频道游标，按对话段落整理新消息`);
}

export function onMemoryMessage(channel: string): void {
  schedulePlanning(channel);
}

export async function flushMemory(channel: string): Promise<void> {
  const planning = planningTimers.get(channel);
  if (planning) clearTimeout(planning);
  planningTimers.delete(channel);
  const scheduled = scanTimers.get(channel);
  if (scheduled) clearTimeout(scheduled);
  scanTimers.delete(channel);
  await scanChannel(channel, true);
  await refreshDerivedMemory(channel, { forceAll: true });
  schedulePlanning(channel);
}
