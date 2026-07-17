import { accounts } from "../accounts";
import { ownerTextMessagesAfter, type LogMessage } from "../conversation/log";
import { chat, extractJson } from "../provider";
import { GEN } from "../settings";
import { beijingDateTime } from "../time";
import { isLowSignalText } from "../textSignals";
import { refreshDerivedMemory } from "./derived";
import {
  addMemory,
  advanceMemoryCursor,
  archiveSiblingMemories,
  findActiveMemoryByKey,
  initializeMemoryCursor,
  memoryCursor,
  normalizedMemorySubjects,
  reconcileMemoryLifecycle,
  searchMemory,
  transitionMemory,
  type MemoryCandidate,
  type MemoryItem,
  type MemoryLayer,
} from "./store";

interface ExtractedMemory {
  operation?: "upsert" | "append" | "retract" | "complete" | "cancel";
  layer?: string;
  kind?: "observation";
  memoryKey?: string;
  subjects?: string[];
  content?: string;
  category?: string;
  confidence?: number;
  importance?: number;
  validHours?: number;
  sourceMemoryKeys?: string[];
  metadata?: Record<string, unknown>;
  reason?: string;
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

function systemPrompt(): string {
  const people = accounts().map((account) => `${account.username}=${account.name}`).join("、");
  return [
    "基础记忆整理器：仅根据本段新聊天输出 fact/event/plan/state 与可选 daju 观察；禁止 relationship/insight/engagement/instruction。",
    `人物：${people}。subjects 只能是 xu|si|both（内容归属，不是发言人）；共同执行/状态用 both。`,
    "fact=稳定可查询事实（原子）；event=有回忆价值的经历50~120字；plan=未来安排须 validHours(默认720)；state=近三天近况每主体最多一张300~800字 validHours默认72。",
    "operation: upsert|append|retract|complete|cancel。memoryKey 用 {layer}.{subject}.{topic}；state 可用 state.{subject}.recent。同事实复用 key。",
    "勿编造、勿引用消息ID。玩笑/问句/猜测不存。连续经历合并一张 event。dajuChanges 仅 observation，须≥2 个 sourceMemoryKeys（本批基础卡 key），默认30天。",
    'JSON：{"changes":[...],"dajuChanges":[...]} changes≤40；无变更则空数组。',
  ].join("\n");
}

function messageLine(message: LogMessage): string {
  // 批处理最多 80 条：单条正文截断，避免 token 被长消息撑爆。
  const body = message.type === "text" ? message.text.replace(/\s+/g, " ").trim() : `[${message.type}]`;
  return `[${beijingDateTime(message.ts)}] [${message.sender}/${message.senderName}] ${body.slice(0, 240)}`;
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
      Date.now(),
      force,
    ) ?? Number.POSITIVE_INFINITY;
    if (!shouldExtractMemoryBatch(sourceMessages.length, force, dueDelay)) {
      scheduleMemoryScan(channel, dueDelay);
      return;
    }

    const nextCursor = { ts: sourceMessages.at(-1)!.ts, id: sourceMessages.at(-1)!.id };
    // 寒暄不送模型，但仍推进游标，避免永远堵在「嗯嗯」上。
    const modelMessages = sourceMessages.filter(
      (message) => message.type === "text" && !isLowSignalText(message.text),
    );
    if (!modelMessages.length) {
      await advanceMemoryCursor(channel, nextCursor);
      console.log(`[memory] ${channel} 跳过 ${sourceMessages.length} 条低信息量消息`);
      return;
    }

    const output = await chat({
      profile: "task",
      system: systemPrompt(),
      user: `【本批新消息，频道=${channel}】\n${modelMessages.map(messageLine).join("\n")}`,
      gen: GEN.extractFacts,
    });
    if (!output) throw new Error("基础记忆模型无输出");
    const parsed = extractJson<{
      changes?: ExtractedMemory[];
      dajuChanges?: ExtractedMemory[];
    }>(output);
    if (!parsed || !Array.isArray(parsed.changes)) throw new Error("基础记忆 JSON 无效");

    let saved = 0;
    const stateSubjects = new Set<string>();
    const savedBaseByKey = new Map<string, MemoryItem>();
    for (const item of parsed.changes.slice(0, 40)) {
      const operation = item.operation ?? "upsert";
      if (!item.layer || !BASE_MEMORY_LAYERS.has(item.layer as MemoryLayer)) continue;
      const layer = item.layer as MemoryLayer;
      const subjects = normalizedMemorySubjects(item.subjects ?? []);
      if (subjects.length !== 1) continue;
      const subject = subjects[0];
      const memoryKey = layer === "state" ? `state.${subject}.recent` : item.memoryKey;
      if (!memoryKey) continue;

      if (["retract", "complete", "cancel"].includes(operation)) {
        const target = await findActiveMemoryByKey({
          scope: channel,
          layer,
          perspective: "people",
          kind: "standard",
          memoryKey,
          subjects,
        });
        if (!target) continue;
        if ((operation === "complete" || operation === "cancel") && target.layer !== "plan") continue;
        const status = operation === "complete" ? "completed" : operation === "cancel" ? "cancelled" : "retracted";
        if (await transitionMemory({
          memoryId: target.id,
          scope: channel,
          status,
          reason: item.reason,
        })) saved += 1;
        continue;
      }

      if (!item.content) continue;
      if (layer === "state" && stateSubjects.has(subject)) continue;
      if (layer === "state") stateSubjects.add(subject);

      const baseTime = sourceMessages.at(-1)?.ts ?? Date.now();
      const suppliedValidHours = Number(item.validHours);
      const validHours = Number.isFinite(suppliedValidHours) && suppliedValidHours > 0
        ? Math.min(24 * 365, suppliedValidHours)
        : layer === "state" ? 72 : layer === "plan" ? 24 * 30 : null;
      let targetForUpdate: MemoryItem | undefined;
      if (layer === "fact" || layer === "plan") {
        targetForUpdate = await findActiveMemoryByKey({
          scope: channel,
          layer,
          perspective: "people",
          kind: "standard",
          memoryKey,
          subjects,
        }) ?? undefined;
        if (!targetForUpdate) {
          const candidate = (await searchMemory({
            query: item.content,
            layers: [layer],
            scopes: [channel],
            perspectives: ["people"],
            kinds: ["standard"],
            subjects,
            subjectMode: "exact",
            limit: 1,
          }))[0];
          if (candidate && (candidate.lexicalHits >= 2 || candidate.score >= 0.82)) {
            targetForUpdate = candidate;
          }
        }
      }
      const candidate: MemoryCandidate = {
        layer,
        scope: channel,
        memoryKey: targetForUpdate?.memoryKey ?? memoryKey,
        subjects,
        speakers: [],
        content: item.content,
        category: item.category,
        confidence: item.confidence,
        importance: item.importance,
        occurredAt: layer === "event" ? baseTime : null,
        validFrom: layer !== "event" ? baseTime : null,
        validUntil: validHours && (layer === "state" || layer === "plan")
          ? baseTime + validHours * 60 * 60 * 1000
          : null,
        metadata: { ...item.metadata, updateReason: item.reason ?? "", extractorVersion: 4 },
        targetMemoryId: targetForUpdate?.id,
      };
      const stored = await addMemory(candidate);
      if (stored) {
        saved += 1;
        savedBaseByKey.set(memoryKey, stored);
        savedBaseByKey.set(stored.memoryKey, stored);
        if (layer === "state") await archiveSiblingMemories(stored.id, true);
      }
    }

    for (const item of (parsed.dajuChanges ?? []).slice(0, 20)) {
      const operation = item.operation ?? "upsert";
      const subjects = normalizedMemorySubjects(item.subjects ?? []);
      if (!item.memoryKey || subjects.length !== 1) continue;
      const target = await findActiveMemoryByKey({
        scope: channel,
        layer: "insight",
        perspective: "daju",
        kind: "observation",
        memoryKey: item.memoryKey,
        subjects,
      });
      if (["retract", "complete", "cancel"].includes(operation)) {
        if (!target) continue;
        const status = operation === "complete" ? "completed" : operation === "cancel" ? "cancelled" : "retracted";
        if (await transitionMemory({
          memoryId: target.id,
          scope: channel,
          status,
          reason: item.reason,
        })) saved += 1;
        continue;
      }

      const kind = item.kind;
      if (!item.content || !item.memoryKey || kind !== "observation") continue;
      const layer = "insight";
      const sourceMemoryIds = [...new Set(item.sourceMemoryKeys ?? [])]
        .map((key) => savedBaseByKey.get(key)?.id)
        .filter((id): id is string => Boolean(id))
        .slice(0, 20);
      if (sourceMemoryIds.length < 2) continue;

      const baseTime = sourceMessages.at(-1)?.ts ?? Date.now();
      const suppliedValidHours = Number(item.validHours);
      const validHours = Number.isFinite(suppliedValidHours) && suppliedValidHours > 0
        ? Math.min(24 * 365, suppliedValidHours)
        : 30 * 24;
      const stored = await addMemory({
        layer,
        perspective: "daju",
        kind,
        scope: channel,
        memoryKey: target?.memoryKey ?? item.memoryKey,
        subjects,
        speakers: [],
        content: item.content,
        category: "大橘观察",
        confidence: item.confidence,
        importance: item.importance ?? 3,
        validFrom: baseTime,
        validUntil: validHours ? baseTime + validHours * 60 * 60 * 1000 : null,
        metadata: {
          ...item.metadata,
          dajuMemory: true,
          extractorVersion: 1,
          updateReason: item.reason ?? "",
        },
        sourceMemoryIds,
        targetMemoryId: target?.id,
      });
      if (stored) {
        saved += 1;
        await archiveSiblingMemories(stored.id, false);
      }
    }

    await advanceMemoryCursor(channel, nextCursor);
    await reconcileMemoryLifecycle();
    // 无新卡时不必跑派生（省一次大模型调用）
    if (saved > 0) {
      await refreshDerivedMemory(channel);
    }
    console.log(
      `[memory] ${channel} 整理 ${modelMessages.length}/${sourceMessages.length} 条消息，写入/更新 ${saved} 条基础记忆`,
    );
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
