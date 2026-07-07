// 意图判断：回复前先跑一轮轻量 LLM 调用，决定这轮要不要联网 / 翻长期记忆 /
// 翻短期记忆 / 检索历史 / 查任务 / 查宠物状态 / 看图 / 反问澄清。
// 判断失败（模型没配置/超时/解析失败）时退回安全默认值——记忆检索照常开着，
// 新增的能力（联网/看图/任务/宠物状态/澄清）默认关闭，绝不会因为这一步失败就答不出来。

import { chat, extractJson } from "./provider";
import { compactLine, type LogMessage } from "./chatLog";
import { GEN } from "./params";
import { accounts } from "./memoryStore";

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

// ─── 独立检索词生成 ──────────────────────────────────────────────────────
// 与 classifyIntent 并行执行，专门为向量检索生成高质量检索词。
// 移植自旧后端 buildRetrievalQuerySystem (chat/src/ai/prompts.js:206-239)，
// 核心区分「交互壳」(大橘你知不知道) 和「检索本体」(林一 小偲发小)。

export interface RetrievalPlan {
  retrievalQuery: string;
  resolvedQuestion: string;
}

const FORBIDDEN_TAILS =
  "相关|相关信息|相关旧事|事情|东西|内容|情况|关系|回忆|记忆|知道|询问|更多|其他|别的|片段|线索|背景|问大橘|知不知道";

function buildRetrievalQuerySystem(): string {
  const names = accounts().map((a) => a.name).join("、");
  return [
    "你是聊天记忆检索词生成器，只负责给向量检索生成 retrievalQuery，不负责判断意图，也不回复用户。",
    "必须只输出一个 JSON 对象，不要 markdown，不要解释。",
    "",
    `两位主人：${names || "他们俩"}。`,
    "",
    '输出 JSON 形状：{"retrievalQuery":"检索对象 + 用户明确限定的面向","resolvedQuestion":"把当前请求按上下文补全成一句自然问题"}',
    "",
    "设计原则：",
    "- retrievalQuery 不是一句话，也不是问题摘要；它是「去历史记忆里搜索的对象」。",
    "- 只根据【最近聊天】和【当前请求】生成，不使用记忆文档，不补充聊天里没有的身份解释。",
    "- 要根据最近聊天做指代消解：如果「你妈/你老婆/那个发小/她」在上下文里已经对应到某个名字或具体身份，就输出那个名字或具体身份；不要把口语壳本身写进 retrievalQuery。",
    "- 不要把口语称呼改写成聊天里没出现过的新称谓。例如原文是「你妈的发小」，上下文提到「林一」，就写「林一 发小」；不要写「你妈 发小」，也不要写「大橘妈妈/小偲妈妈」。",
    "- 先确定【检索对象】：具体人名、已消解的身份称呼、地点、物品、事件名称。例如：林一、小旭发小、小偲发小、导师、论文挂名。",
    "- 再确定【限定面向】：只有用户当前明确要求某个面向，或紧邻上文明确仍在展开某个面向时，才加入这个面向。例如：吃醋、争吵、表白、论文挂名。不要默认添加「称呼/认识背景」；只有用户明确问怎么称呼、怎么认识、什么背景时才写。",
    "- 如果用户只是问「还有更多吗/还有别的吗/继续说/还有吗」，不要添加任何新的限定面向；retrievalQuery 只保留检索对象。不要写「更多/其他/片段/线索/背景/事情」。",
    "- 不要把大橘上一条回答里已经讲过的具体内容放进 retrievalQuery，除非用户点名说「继续讲那个」。上一条回答只用来识别主对象。",
    "- 不要为了凑长度而添加泛词。宁可短，也不要脏。好的 retrievalQuery 可以只有 1-3 个词。",
    `- 禁止出现在 retrievalQuery 里的词：${FORBIDDEN_TAILS}。`,
    "- resolvedQuestion 可以是自然句，用来说明用户真正想问什么；它可以包含「知道/记得/问/更多」，但 retrievalQuery 不要包含这些交互词或泛词。",
    "",
    "例子：",
    '- 上文只在问「小偲发小林一，大橘知不知道」 → {"retrievalQuery":"林一 发小","resolvedQuestion":"关于小偲发小林一，你知道什么？"}',
    '- 用户说「那你妈的发小呢」，上文提到这个发小叫林一 → {"retrievalQuery":"林一 发小","resolvedQuestion":"关于那个叫林一的发小，你知道什么？"}',
    '- 上文在讨论林一引发吃醋 → {"retrievalQuery":"林一 小偲发小 小旭吃醋 争吵 旧账","resolvedQuestion":"之前林一相关的吃醋和争执是怎么回事？"}',
    '- 用户纠正「我问的是我发小，不是小偲发小」 → {"retrievalQuery":"小旭发小","resolvedQuestion":"关于小旭自己的发小，你知道什么？"}',
    '- 大橘刚讲了「小旭发小」的两个故事，用户问「还有更多的吗」 → {"retrievalQuery":"小旭发小","resolvedQuestion":"关于小旭的发小，还有别的故事吗？"}',
    '- 大橘刚讲了「小旭发小」的女权争辩和表白，用户问「表白那个详细说说」 → {"retrievalQuery":"小旭发小 表白","resolvedQuestion":"小旭发小表白那件事具体是怎样的？"}',
  ].join("\n");
}

function buildRetrievalQueryUser(question: string, recent: LogMessage[]): string {
  const lines = recent
    .filter((m) => m.kind !== "system")
    .map((m) => compactLine(m, 180))
    .filter(Boolean)
    .slice(-36)
    .join("\n");
  const requestText = String(question || "").trim()
    || "（只有触发词/空召唤：请根据最近聊天最后一个未完成话题生成检索词）";
  return [
    lines ? `【最近聊天】\n${lines}` : "",
    `【当前请求】\n${requestText}`,
    "",
    "请只生成 retrievalQuery 和 resolvedQuestion。",
    "retrievalQuery 只写最近聊天原文里能支撑、并已按上下文消解后的检索对象和用户明确限定的面向；如果只是追问「更多」，只写主对象，不要写「更多/其他/片段/线索/背景/关系」。",
  ].filter((x) => x !== "").join("\n");
}

export async function generateRetrievalQuery(
  question: string,
  recent: LogMessage[],
): Promise<RetrievalPlan> {
  const fallback: RetrievalPlan = { retrievalQuery: question, resolvedQuestion: question };
  const out = await chat({
    profile: "task",
    system: buildRetrievalQuerySystem(),
    user: buildRetrievalQueryUser(question, recent),
    gen: GEN.retrievalQuery,
  });
  const parsed = extractJson<Record<string, unknown>>(out);
  if (!parsed) return fallback;
  const retrievalQuery = typeof parsed.retrievalQuery === "string" && parsed.retrievalQuery.trim()
    ? parsed.retrievalQuery.trim().slice(0, 300)
    : fallback.retrievalQuery;
  const resolvedQuestion = typeof parsed.resolvedQuestion === "string" && parsed.resolvedQuestion.trim()
    ? parsed.resolvedQuestion.trim().slice(0, 300)
    : fallback.resolvedQuestion;
  return { retrievalQuery, resolvedQuestion };
}
