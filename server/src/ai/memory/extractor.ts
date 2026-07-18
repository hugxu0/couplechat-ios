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
const SYSTEM_MEMORY_SYNC = { actorAccountId: null } as const;

export const MEMORY_SOURCE_BATCH_SIZE = 80;
export const MEMORY_BUSY_BATCH_THRESHOLD = 20;
export const MEMORY_BUSY_IDLE_MS = 15 * 60 * 1000;
export const MEMORY_QUIET_IDLE_MS = 60 * 60 * 1000;
export const MEMORY_MAX_BATCH_AGE_MS = 2 * 60 * 60 * 1000;
export const MEMORY_EMPTY_RETRY_THRESHOLD = 12;

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

export function shouldRetryEmptyMemoryBatch(
  modelMessageCount: number,
  candidateCount: number,
): boolean {
  return modelMessageCount >= MEMORY_EMPTY_RETRY_THRESHOLD && candidateCount === 0;
}

function systemPrompt(): string {
  const people = accounts().map((account) => `${account.username}=${account.name}`).join("、");
  return [
    "你是 CoupleChat 的基础记忆整理器。输入只有一段连续的新聊天，只能根据这批消息整理，不得假设旧记忆正文。",
    "changes 只允许 fact、event、plan、state；禁止 relationship、insight、engagement 和 instruction。高层关系/理解由另一阶段根据基础卡生成。",
    `人物 username：${people}。subjects 必须且只能是单个逻辑主体 xu、si 或 both；它表示内容属于谁，不是发言人。只属于一人的事情归该人，只有共同参与、共同承担或两人的整体状态才用 both。`,
    "fact：稳定且以后值得直接查询的原子事实，例如身份、偏好、习惯、健康禁忌、工作、家庭和重要人物。",
    "event：已经发生且以后值得回忆或检索的一次经历，约 50~120 字，独立写清人物、时间线索、事情和结果。不要把每句日常聊天都变成 event。",
    "plan：未来安排、承诺或准备做的事；必须给 validHours，未明确期限默认 720 小时。完成、取消或明确否定旧计划时输出对应 operation。",
    "state：近三天滚动近况，可记录活动、健康、情绪、正在讨论的主题、双方观点和分歧。每个主体本批最多一张，内容应具体连贯，validHours 默认 72 小时。",
    "operation 只能是 upsert|append|retract|complete|cancel。fact/plan 更新时复用稳定 memoryKey；state 使用 state.{subject}.recent；其他 key 使用 {layer}.{subject}.{topic}。",
    "连续的同一次经历合并成一张 event；近况里的琐碎活动不要重复生成为 event。玩笑、问句、未确认猜测、辱骂中的人格判断不保存。不得编造日期，不得输出或引用消息 ID。",
    `本批经过低信息量过滤后若仍有至少 ${MEMORY_EMPTY_RETRY_THRESHOLD} 条真实交流，并出现活动、感受、健康、争执、决定、计划或持续讨论主题，至少输出一张 state；只有确实没有任何可整理信息时 changes 才能为空。`,
    "dajuChanges 只允许 observation；必须引用本批实际 changes 中至少两个 sourceMemoryKeys，默认有效 30 天。主人对大橘的长期行为要求由对话 Agent 直接保存，这里不得生成 instruction。",
    "confidence 范围 0~1，importance 范围 1~5，changes 最多 40 条。示例仅说明字段，不得复制示例正文。",
    '只输出合法 JSON，例如：{"changes":[{"operation":"upsert","layer":"state","memoryKey":"state.xu.recent","subjects":["xu"],"content":"根据本批聊天概括的近期状态","validHours":72,"confidence":0.8,"importance":3}],"dajuChanges":[]}',
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
      scope: "memory.extract",
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
    const candidateChanges = parsed.changes.slice(0, 40);
    const candidateDajuChanges = (parsed.dajuChanges ?? []).slice(0, 20);
    if (shouldRetryEmptyMemoryBatch(modelMessages.length, candidateChanges.length)) {
      throw new Error(
        `基础记忆模型对 ${modelMessages.length} 条有效消息返回零候选，保留游标等待重试`,
      );
    }

    let saved = 0;
    const stateSubjects = new Set<string>();
    const savedBaseByKey = new Map<string, MemoryItem>();
    for (const item of candidateChanges) {
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
      const stored = await addMemory(candidate, SYSTEM_MEMORY_SYNC);
      if (stored) {
        saved += 1;
        savedBaseByKey.set(memoryKey, stored);
        savedBaseByKey.set(stored.memoryKey, stored);
        if (layer === "state") await archiveSiblingMemories(stored.id, true);
      }
    }

    for (const item of candidateDajuChanges) {
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
      }, SYSTEM_MEMORY_SYNC);
      if (stored) {
        saved += 1;
        await archiveSiblingMemories(stored.id, false);
      }
    }

    await advanceMemoryCursor(channel, nextCursor);
    await reconcileMemoryLifecycle();
    // 同一频道仍串行派生，避免共享 task provider 并发堆积；手动 HTTP
    // 最多等待 20 秒，超时后由该任务继续完成并通过 Sync V2 通知客户端。
    if (saved > 0) {
      await refreshDerivedMemory(channel).catch((error) => {
        console.warn(
          `[memory] ${channel} 派生整理失败:`,
          error instanceof Error ? error.message : error,
        );
      });
    }
    console.log(
      `[memory] ${channel} 整理 ${modelMessages.length}/${sourceMessages.length} 条消息，` +
        `候选 ${candidateChanges.length}/${candidateDajuChanges.length}，写入/更新 ${saved} 条基础记忆`,
    );
    if (candidateChanges.length > 0 && saved === 0) {
      console.warn(
        `[memory] ${channel} 模型返回 ${candidateChanges.length} 条基础候选但全部被校验或排除规则拒绝`,
      );
    }
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
  try {
    await scanChannel(channel, true);
  } finally {
    // 手动整理失败也必须恢复自动规划，不能因清掉旧 timer 后留下永久空窗。
    schedulePlanning(channel);
  }
}
