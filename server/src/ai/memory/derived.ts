import { chat, extractJson } from "../provider";
import { readRuntimeState, writeRuntimeState } from "../runtimeState";
import { GEN } from "../settings";
import {
  addMemory,
  archiveSiblingMemories,
  listActiveMemoryContext,
  type MemoryItem,
} from "./store";

const DAY_MS = 24 * 60 * 60 * 1000;
const RELATIONSHIP_INTERVAL_MS = DAY_MS;
const INSIGHT_INTERVAL_MS = 7 * DAY_MS;
const INSIGHT_CHANGED_SOURCE_THRESHOLD = 20;

interface DerivedCard {
  content?: string;
  sourceMemoryIds?: string[];
  confidence?: number;
  importance?: number;
}

interface DerivedOutput {
  relationship?: DerivedCard | null;
  insight?: DerivedCard | null;
}

interface DerivedRunState {
  relationshipAt: number;
  insightAt: number;
}

function parseState(raw: string): DerivedRunState {
  try {
    const value = JSON.parse(raw) as Partial<DerivedRunState>;
    return {
      relationshipAt: Number(value.relationshipAt) || 0,
      insightAt: Number(value.insightAt) || 0,
    };
  } catch {
    return { relationshipAt: 0, insightAt: 0 };
  }
}

function sourceLine(memory: MemoryItem): string {
  const time = memory.occurredAt ?? memory.validFrom ?? memory.updatedAt;
  return `[${memory.id}] layer=${memory.layer} subject=${memory.subjects[0] ?? "unknown"} time=${time} content=${memory.content.slice(0, 500)}`;
}

function continuityLine(memory: MemoryItem): string {
  return `[${memory.id}] layer=${memory.layer} updatedAt=${memory.updatedAt} content=${memory.content.slice(0, 700)}`;
}

function validSourceIds(card: DerivedCard | null | undefined, allowed: Set<string>): string[] {
  return [...new Set(card?.sourceMemoryIds ?? [])].filter((id) => allowed.has(id)).slice(0, 60);
}

function derivedPrompt(relationshipDue: boolean, insightDue: boolean): string {
  return [
    "你是 CoupleChat 的高层记忆整理器。输入是已经核验过的事实、经历、计划和近况卡片，不是聊天原文。",
    "只能根据输入卡片综合，不能补写没有来源的情节；每个结论都要列出实际使用的 sourceMemoryIds。",
    relationshipDue
      ? "relationship：生成一张两个人近期关系的滚动总结。重点写最近相处状态、亲密或疏离、争执及原因、见面后的变化；不要把普通共同约定机械重复成关系条目。内容应具体、连贯，可保留重要背景。"
      : "relationship 必须输出 null。",
    insightDue
      ? "insight：生成一张两个人互动方式的谨慎理解。提炼反复出现的沟通偏好、有效做法和容易产生误会的模式；不要心理诊断，不要把单次事件夸大为规律。"
      : "insight 必须输出 null。",
    "subjects 固定为 both，由代码写入。若来源不足以形成可靠卡片，相应字段输出 null。",
    '只输出 JSON：{"relationship":{"content":"...","sourceMemoryIds":["mem_x"],"confidence":0.8,"importance":4},"insight":null}',
  ].join("\n");
}

export async function refreshDerivedMemory(
  channel: string,
  options: { forceRelationship?: boolean; forceAll?: boolean } = {},
): Promise<{ relationship: boolean; insight: boolean }> {
  if (channel !== "couple") return { relationship: false, insight: false };
  const now = Date.now();
  const stateKey = `memory:derived:${channel}`;
  const state = parseState(await readRuntimeState(stateKey));
  const allActive = await listActiveMemoryContext(channel, 180);
  const eligibleSources = allActive.filter((memory) => {
    if (!["fact", "event", "plan", "state"].includes(memory.layer)) return false;
    if (memory.layer !== "event") return true;
    return (memory.occurredAt ?? memory.updatedAt) >= now - 30 * DAY_MS;
  });
  const sources = [
    ...eligibleSources.filter((memory) => memory.layer !== "event").slice(0, 40),
    ...eligibleSources.filter((memory) => memory.layer === "event").slice(0, 40),
  ];
  if (!sources.length) return { relationship: false, insight: false };

  const relationshipDue = Boolean(options.forceAll || options.forceRelationship
    || !state.relationshipAt || now - state.relationshipAt >= RELATIONSHIP_INTERVAL_MS);
  const changedSinceInsight = sources.filter((memory) => memory.updatedAt > state.insightAt).length;
  const insightDue = Boolean(options.forceAll || !state.insightAt
    || now - state.insightAt >= INSIGHT_INTERVAL_MS
    || changedSinceInsight >= INSIGHT_CHANGED_SOURCE_THRESHOLD);
  if (!relationshipDue && !insightDue) return { relationship: false, insight: false };

  const continuity = allActive.filter((memory) =>
    memory.layer === "relationship" || memory.layer === "insight").slice(0, 12);
  const output = await chat({
    profile: "task",
    system: derivedPrompt(relationshipDue, insightDue),
    user: [
      `【基础记忆卡】\n${sources.map(sourceLine).join("\n")}`,
      `【旧高层卡，仅用于保持连续】\n${continuity.map(continuityLine).join("\n") || "（无）"}`,
    ].join("\n\n"),
    gen: { ...GEN.extractFacts, timeoutMs: 120_000 },
  });
  if (!output) throw new Error("派生记忆模型无输出");
  const parsed = extractJson<DerivedOutput>(output);
  if (!parsed) throw new Error("派生记忆 JSON 无效");
  const allowed = new Set(sources.map((memory) => memory.id));
  let relationship = false;
  let insight = false;

  if (relationshipDue) {
    const sourceMemoryIds = validSourceIds(parsed.relationship, allowed);
    if (parsed.relationship?.content && sourceMemoryIds.length) {
      const saved = await addMemory({
        layer: "relationship",
        scope: channel,
        memoryKey: "relationship.both.recent",
        subjects: ["both"],
        speakers: [],
        content: parsed.relationship.content,
        category: "近期关系",
        confidence: Math.min(0.9, Number(parsed.relationship.confidence) || 0.75),
        importance: parsed.relationship.importance,
        validFrom: now,
        metadata: { derived: true, synthesis: "relationship", sourceWindowDays: 30 },
        sourceMemoryIds,
      });
      if (saved) {
        await archiveSiblingMemories(saved.id, false, now);
        relationship = true;
      }
    }
    state.relationshipAt = now;
  }

  if (insightDue) {
    const sourceMemoryIds = validSourceIds(parsed.insight, allowed);
    if (parsed.insight?.content && sourceMemoryIds.length >= 3) {
      const saved = await addMemory({
        layer: "insight",
        scope: channel,
        memoryKey: "insight.both.interaction",
        subjects: ["both"],
        speakers: [],
        content: parsed.insight.content,
        category: "互动理解",
        confidence: Math.min(0.82, Number(parsed.insight.confidence) || 0.68),
        importance: parsed.insight.importance,
        validFrom: now,
        metadata: { derived: true, synthesis: "interaction", sourceWindowDays: 30 },
        sourceMemoryIds,
      });
      if (saved) {
        await archiveSiblingMemories(saved.id, false, now);
        insight = true;
      }
    }
    state.insightAt = now;
  }

  await writeRuntimeState(stateKey, JSON.stringify(state));
  return { relationship, insight };
}
