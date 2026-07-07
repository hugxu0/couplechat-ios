// 意图判断：回复前先跑一轮轻量 LLM 调用，决定这轮要不要联网 / 翻长期记忆 /
// 翻短期记忆 / 检索历史 / 查任务 / 查宠物状态 / 看图 / 反问澄清。
// 判断失败（模型没配置/超时/解析失败）时退回安全默认值——记忆检索照常开着，
// 新增的能力（联网/看图/任务/宠物状态/澄清）默认关闭，绝不会因为这一步失败就答不出来。

import { chat, extractJson } from "./provider";
import { compactLine, type LogMessage } from "./chatLog";
import { GEN } from "./params";

export interface PlanContext {
  intent: string;
  confidence: number;
  needSearch: boolean;
  needMemory: boolean;
  needShortMemory: boolean;
  needRetrieval: boolean;
  needTasks: boolean;
  needPetStatus: boolean;
  needImages: boolean;
  needClarification: boolean;
  retrievalQuery: string;
  resolvedQuestion: string;
}

function fallbackPlan(question: string): PlanContext {
  return {
    intent: "chat",
    confidence: 0,
    needSearch: false,
    needMemory: true,
    needShortMemory: true,
    needRetrieval: false,
    needTasks: false,
    needPetStatus: false,
    needImages: false,
    needClarification: false,
    retrievalQuery: question,
    resolvedQuestion: question,
  };
}

function buildSystem(): string {
  return [
    "你是「大橘」（情侣聊天助手）内部的意图判断模块，不直接跟用户说话，只输出 JSON 供程序使用。",
    "根据用户这句话和最近聊天，判断接下来生成回复需要用到哪些能力：",
    "- needSearch：需要联网查实时/最新信息（比如比赛结果、新闻）才能回答。",
    "- needMemory：需要长期事实记忆辅助回答（对方的偏好/习惯/雷区/纪念日等）。",
    "- needShortMemory：需要最近一周内的近况辅助回答。",
    "- needRetrieval：需要检索更早的历史聊天原文或事件卡片才能回答。",
    "- needTasks：问到了提醒/备忘相关的内容。",
    "- needPetStatus：问到了大橘自己的状态（饱食/心情/精力等）。",
    "- needImages：最近聊天里有张图片跟这句话相关，需要看一眼才能回答（没有相关图片就是 false）。",
    "- needClarification：问题太模糊，需要先反问澄清再回答。",
    "- retrievalQuery：需要检索时给出适合向量搜索的关键词，不需要检索就给空字符串。",
    "- resolvedQuestion：把「这个/那个/他/她/刚才」这类指代补全成独立可理解的问题；补不出来就原样返回。",
    '只输出 JSON，不要输出多余文字：{"intent":"chat","confidence":0.9,"needSearch":false,"needMemory":true,"needShortMemory":true,"needRetrieval":false,"needTasks":false,"needPetStatus":false,"needImages":false,"needClarification":false,"retrievalQuery":"","resolvedQuestion":"..."}',
  ].join("\n");
}

function buildUser(question: string, recent: LogMessage[]): string {
  const lines = recent
    .filter((m) => m.kind !== "system")
    .map((m) => compactLine(m))
    .filter(Boolean)
    .slice(-12)
    .join("\n");
  return [
    lines ? `【最近聊天】\n${lines}` : "",
    `【这句话】\n${question || "（没有正文，可能只是唤了一声）"}`,
  ].filter(Boolean).join("\n\n");
}

function toBool(v: unknown, fallback: boolean): boolean {
  if (typeof v === "boolean") return v;
  if (typeof v === "string") return v === "true" || v === "是";
  return fallback;
}

export async function classifyIntent(question: string, recent: LogMessage[]): Promise<PlanContext> {
  const fallback = fallbackPlan(question);
  const out = await chat({
    profile: "task",
    system: buildSystem(),
    user: buildUser(question, recent),
    gen: GEN.intent,
  });
  const parsed = extractJson<Record<string, unknown>>(out);
  if (!parsed) return fallback;
  return {
    intent: typeof parsed.intent === "string" && parsed.intent.trim() ? parsed.intent.trim() : fallback.intent,
    confidence: typeof parsed.confidence === "number" ? parsed.confidence : fallback.confidence,
    needSearch: toBool(parsed.needSearch, fallback.needSearch),
    needMemory: toBool(parsed.needMemory, fallback.needMemory),
    needShortMemory: toBool(parsed.needShortMemory, fallback.needShortMemory),
    needRetrieval: toBool(parsed.needRetrieval, fallback.needRetrieval),
    needTasks: toBool(parsed.needTasks, fallback.needTasks),
    needPetStatus: toBool(parsed.needPetStatus, fallback.needPetStatus),
    needImages: toBool(parsed.needImages, fallback.needImages),
    needClarification: toBool(parsed.needClarification, fallback.needClarification),
    retrievalQuery: typeof parsed.retrievalQuery === "string" && parsed.retrievalQuery.trim()
      ? parsed.retrievalQuery.trim()
      : fallback.retrievalQuery,
    resolvedQuestion: typeof parsed.resolvedQuestion === "string" && parsed.resolvedQuestion.trim()
      ? parsed.resolvedQuestion.trim()
      : fallback.resolvedQuestion,
  };
}
