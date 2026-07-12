import { accounts } from "../accounts";
import { ownerTextMessagesAfter, type LogMessage } from "../conversation/log";
import { chat, extractJson } from "../provider";
import { GEN } from "../settings";
import { beijingDateTime } from "../time";
import {
  addMemory,
  advanceMemoryCursor,
  initializeMemoryCursor,
  listActiveMemoryContext,
  memoryCursor,
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

const timers = new Map<string, NodeJS.Timeout>();
const running = new Set<string>();
const retryAttempts = new Map<string, number>();
export const MEMORY_SOURCE_BATCH_SIZE = 30;

export function shouldExtractMemoryBatch(sourceMessageCount: number, force = false): boolean {
  return sourceMessageCount > 0 && (force || sourceMessageCount >= MEMORY_SOURCE_BATCH_SIZE);
}

function systemPrompt(includeEngagement: boolean): string {
  const people = accounts().map((account) => `${account.username}=${account.name}`).join("、");
  return [
    "你是 CoupleChat 的记忆变更分类器。输入包含当前有效记忆和一批新消息；输出本批消息对记忆造成的变更。",
    `人物 username：${people}。subjects 只能使用这些 username、both 或 daju。`,
    "六种派生记忆层：",
    "fact：相对稳定且可被未来问题直接查询的事实，例如身份、喜好、习惯、健康禁忌、重要人物。",
    "event：有具体发生时间的一次经历。用药、就医、身体异常、旅行、见面、争执、购买、比赛结果等即使只发生一次，只要未来可能问‘有没有/什么时候’就保存。",
    "plan：未来安排、承诺和准备做的事情。必须给 validHours；未明确期限时给 720（30 天），明确长期安排可按实际期限给值。提醒/备忘真正执行仍由业务系统确认。",
    "state：短期变化状态，例如感冒、忙碌、情绪、正在旅行。必须给 validHours，默认 24~168 小时，不能永久有效。",
    "relationship：双方明确表达或达成的关系身份、共同约定和边界。单次情绪评价不能写入。",
    "insight：基于本批至少三条相互支持消息的谨慎模式观察。普通单次对话不要生成 insight，不能做心理诊断。",
    "operation 规则：upsert 新增或更新事实/计划/状态/关系/洞察；append 追加事件；retract 表示主人明确否定或纠正一条旧记忆；complete/cancel 只用于计划已完成或取消。",
    "更新、否定、完成或取消已有记忆时，必须使用输入中的 targetMemoryId，并原样复用它的 memoryKey。不要为同一主题另造近义 key。",
    "每条变更必须原子化，并引用 sourceMessageIds；只能引用本批新消息中真实存在的 id。",
    "同一段连续经历默认合成一条 event，保留起因、关键过程和结果；不要按说话人、步骤或每句话拆成多条。只有内容确实属于不同记忆层时才拆，单个话题最多两条。",
    "双方共同经历、共同讨论或共同约定的 subjects 使用 both，不要输出两个 username。",
    "新主题的 memoryKey 使用稳定的‘层.主体.槽位’结构，不包含时间、随机词或具体取值。事件 key 表示事件类型和主要对象。",
    "occurredMessageId 指向最能代表事件发生时间的证据消息；没有则省略。不要自己编造日期。",
    "confidence 0~1；只有主人明确说出的内容才可高于 0.85。importance 1~5。",
    "insight 必须引用至少三条相互支持的新消息；代码会拒绝证据不足的洞察。",
    "玩笑、问句本身、AI 旧回复、无明确答案的猜测、辱骂中的人格判断均不保存。",
    ...(includeEngagement ? [
      "同时对本批公聊给出 engagement 信号，但不要生成回复：",
      "conflict：只有双方明显紧张、攻击、阴阳怪气或持续升级，确实值得介入；玩笑、撒娇式抱怨、平和分歧不算。",
      "interject：没有冲突，但有具体、只属于这对情侣的有价值补充；普通闲聊必须 none。conflict 优先于 interject。",
      "reason 只是交给后续 Agent 的不可信提示，不是记忆也不是事实。宁可 none，不要为了搭话硬找理由。",
      '只输出 JSON：{"changes":[{"operation":"upsert","targetMemoryId":"可选","layer":"fact","memoryKey":"稳定键","subjects":["xu"],"content":"原子事实","category":"类别","confidence":0.9,"importance":3,"sourceMessageIds":["msg_x"],"occurredMessageId":"msg_x","validHours":72,"reason":"变更原因","metadata":{}}],"engagement":{"kind":"none","confidence":0.0,"reason":""}}',
      "没有记忆变更时 changes 使用空数组，但仍必须输出 engagement。",
    ] : [
      '只输出 JSON：{"changes":[{"operation":"upsert","targetMemoryId":"可选","layer":"fact","memoryKey":"稳定键","subjects":["xu"],"content":"原子事实","category":"类别","confidence":0.9,"importance":3,"sourceMessageIds":["msg_x"],"occurredMessageId":"msg_x","validHours":72,"reason":"变更原因","metadata":{}}]}',
      '没有记忆变更时输出 {"changes":[]}。',
    ]),
    "changes 最多 30 条；优先合并连续事件，不得因条数上限省略已识别的独立变更。",
  ].join("\n");
}

function messageLine(message: LogMessage): string {
  const body = message.type === "text" ? message.text.replace(/\s+/g, " ").trim() : `[${message.type}]`;
  return `[${message.id}] [${beijingDateTime(message.ts)}] [${message.sender}/${message.senderName}] ${body.slice(0, 800)}`;
}

function normalizedSubject(value: string): string | null {
  if (value === "both" || value === "daju") return value;
  const account = accounts().find((item) => item.username === value || item.name === value);
  return account?.username ?? null;
}

function normalizedSubjects(values: string[]): string[] {
  const subjects = [...new Set(values.map(normalizedSubject).filter((value): value is string => Boolean(value)))];
  if (subjects.includes("both")) return ["both"];
  const ownerUsernames = accounts().map((account) => account.username);
  if (ownerUsernames.length > 1 && ownerUsernames.every((username) => subjects.includes(username))) return ["both"];
  return subjects;
}

function memoryContextLine(memory: MemoryItem): string {
  return `[${memory.id}] layer=${memory.layer} key=${memory.memoryKey} subjects=${memory.subjects.join(",")} content=${memory.content.slice(0, 240)}`;
}

export function minimumEvidenceForLayer(layer: MemoryLayer): number {
  return layer === "insight" ? 3 : 1;
}

async function scanChannel(channel: string, force = false): Promise<void> {
  if (running.has(channel)) return;
  running.add(channel);
  let batchWasFull = false;
  let batchCompleted = false;
  try {
    const cursor = await memoryCursor(channel);
    if (!cursor.ts) {
      await initializeMemoryCursor(channel);
      return;
    }
    const sourceMessages = await ownerTextMessagesAfter(channel, cursor, MEMORY_SOURCE_BATCH_SIZE);
    if (!shouldExtractMemoryBatch(sourceMessages.length, force)) return;
    batchWasFull = sourceMessages.length === MEMORY_SOURCE_BATCH_SIZE;
    const nextCursor = {
      ts: sourceMessages[sourceMessages.length - 1].ts,
      id: sourceMessages[sourceMessages.length - 1].id,
    };
    const sourceById = new Map(sourceMessages.map((message) => [message.id, message]));
    const activeMemories = await listActiveMemoryContext(channel, 160);
    const activeById = new Map(activeMemories.map((memory) => [memory.id, memory]));
    const output = await chat({
      profile: "task",
      system: systemPrompt(channel === "couple"),
      user: [
        `【当前有效记忆，频道=${channel}】\n${activeMemories.map(memoryContextLine).join("\n") || "（空）"}`,
        `【本批新消息】\n${sourceMessages.map(messageLine).join("\n")}`,
      ].join("\n\n"),
      gen: GEN.extractFacts,
    });
    if (!output) throw new Error("记忆分类模型无输出");
    const parsed = extractJson<{ changes?: ExtractedMemory[]; engagement?: ExtractedEngagement }>(output);
    if (!parsed || !Array.isArray(parsed.changes)) throw new Error("记忆变更 JSON 无效");

    let saved = 0;
    for (const item of parsed.changes.slice(0, 30)) {
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
      if (!item.content || !item.memoryKey || !MEMORY_LAYERS.has(String(item.layer))) continue;
      const subjects = normalizedSubjects(item.subjects ?? []);
      if (!subjects.length) continue;
      const occurredMessage = item.occurredMessageId ? sourceById.get(item.occurredMessageId) : undefined;
      const firstEvidence = sourceById.get(sourceIds[0]);
      const layer = item.layer as MemoryLayer;
      if (sourceIds.length < minimumEvidenceForLayer(layer)) continue;
      if (target && target.layer !== layer) continue;
      const suppliedValidHours = Number(item.validHours);
      const validHours = Number.isFinite(suppliedValidHours) && suppliedValidHours > 0
        ? Math.min(24 * 365, suppliedValidHours)
        : layer === "state" ? 72
          : layer === "plan" ? 24 * 30
            : null;
      const baseTime = occurredMessage?.ts ?? firstEvidence?.ts ?? Date.now();
      const candidate: MemoryCandidate = {
        layer,
        scope: channel,
        memoryKey: target?.memoryKey ?? item.memoryKey,
        subjects,
        speakers: [...new Set(sourceIds.map((id) => sourceById.get(id)!.sender))],
        content: item.content,
        category: item.category,
        confidence: layer === "insight" ? Math.min(Number(item.confidence ?? 0.6), 0.75) : item.confidence,
        importance: item.importance,
        occurredAt: layer === "event" ? baseTime : null,
        validFrom: ["fact", "plan", "state", "relationship", "insight"].includes(layer) ? baseTime : null,
        validUntil: validHours && (layer === "state" || layer === "plan")
          ? baseTime + validHours * 60 * 60 * 1000
          : null,
        metadata: { ...item.metadata, updateReason: item.reason ?? "" },
        sourceMessageIds: sourceIds,
        targetMemoryId: target?.id,
      };
      if (await addMemory(candidate)) saved += 1;
    }
    await advanceMemoryCursor(channel, nextCursor);
    await reconcileMemoryLifecycle();
    batchCompleted = true;
    const engagement = parsed.engagement;
    const kind = engagement?.kind;
    const confidence = Math.max(0, Math.min(1, Number(engagement?.confidence) || 0));
    const threshold = kind === "conflict" ? 0.7 : 0.78;
    if (channel === "couple" && engagementHandler && (kind === "conflict" || kind === "interject") && confidence >= threshold) {
      const requester = sourceMessages[sourceMessages.length - 1];
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
    console.log(`[memory] ${channel} 处理 ${sourceMessages.length} 条消息，写入/更新 ${saved} 条记忆`);
  } finally {
    running.delete(channel);
    if (batchCompleted && batchWasFull) scheduleMemoryScan(channel, 0);
  }
}

const MEMORY_LAYERS = new Set(["fact", "event", "plan", "state", "relationship", "insight"]);

export async function initializeMemory(): Promise<void> {
  const channels = ["couple", ...accounts().map((account) => `ai:${account.username}`)];
  await Promise.all(channels.map((channel) => initializeMemoryCursor(channel)));
  channels.forEach(onMemoryMessage);
  console.log(`[memory] 已初始化 ${channels.length} 个频道游标，只处理此后的新消息`);
}

export function onMemoryMessage(channel: string): void {
  scheduleMemoryScan(channel, 8_000);
}

function scheduleMemoryScan(channel: string, delayMs: number): void {
  if (timers.has(channel)) return;
  timers.set(channel, setTimeout(() => {
    timers.delete(channel);
    void scanChannel(channel)
      .then(() => retryAttempts.delete(channel))
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
  }, delayMs));
}

export async function flushMemory(channel: string): Promise<void> {
  const timer = timers.get(channel);
  if (timer) clearTimeout(timer);
  timers.delete(channel);
  await scanChannel(channel, true);
}
