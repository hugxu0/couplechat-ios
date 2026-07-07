// 每日维护管线：作息日切换（北京时间早 6 点）后，对「昨天」跑一遍：
//   1. 日记 digest：当天聊天 → 详细日记（记忆整理的原始素材，不展示给用户）
//   2. 事件卡片：当天聊天按话题切卡 → ai_episodes（向量化，供召回）
//   3. 事实收口：白天攒的 fresh 事实 → keep / merge / discard 批量裁决
//   4. 短期记忆重写：近一周叙事文档
//   5. 人物卡 ×2 + 关系卡刷新
// 每步独立完成标记（done:<step>:<date>），失败互不拖累，重启/隔天自动补跑，全程幂等。

import { compactLines, messagesBetween } from "./chatLog";
import {
  accounts,
  addEpisode,
  addFact,
  CATEGORIES,
  deleteEpisodesByDate,
  deleteFact,
  factLine,
  getDoc,
  isJobDone,
  listFacts,
  markJobDone,
  setDoc,
  subjectLabel,
  updateFact,
  type Fact,
} from "./memoryStore";
import { similarity } from "./embeddings";
import { aiEnabled, chat, extractJson } from "./provider";
import { addDays, beijingParts, cycleBounds, cycleDate } from "./time";
import { DAY_ROLLOVER_HOUR, GEN, MEMORY } from "./params";

function names(): [string, string] {
  const list = accounts();
  return [list[0]?.name ?? "小旭", list[1]?.name ?? "小偲"];
}

// ─── 1. 日记 digest ──────────────────────────────────────────────────────

async function generateDigest(date: string): Promise<void> {
  if (isJobDone("digest", date)) return;
  const { start, end } = cycleBounds(date);
  const msgs = messagesBetween("couple", start, end).filter((m) => m.kind !== "system");
  if (!msgs.length) {
    markJobDone("digest", date);
    return;
  }
  const [a, b] = names();
  const out = await chat({
    profile: "task",
    system: [
      "你是大橘，正在整理后台详细日记——这份文档是给你自己后续做记忆整理用的原始素材（短期记忆重写、人物卡都会读它），不会展示给主人看。",
      `两位主人是 ${a} 和 ${b}。正文里提到他们一律直接用这两个名字，不要用「你/你们」这种第二人称。`,
      "记录发生了什么、情绪变化、重要约定、潜在矛盾、值得记住的细节。保持客观温柔，不评判谁对谁错，不复述过多伤人的原话。",
      "直接输出正文（Markdown 小标题分段）：今日概览、情绪与互动、重要事实/约定、需要大橘记住、后续可关注。不要开场白客套话。",
    ].join("\n"),
    user: `日期：${date}\n聊天记录：\n${compactLines(msgs, 260).slice(-18000)}`,
    gen: GEN.dailyDigest,
  });
  if (!out) return; // 失败不标记，下次补跑
  setDoc(`digest:${date}`, out.trim());
  markJobDone("digest", date);
}

// ─── 2. 事件卡片 ─────────────────────────────────────────────────────────

interface RawCard {
  title?: string;
  summary?: string;
  key_points?: unknown;
  mood?: string;
  conclusion?: string;
  keywords?: unknown;
}

async function generateEpisodes(storedChannel: string, date: string): Promise<void> {
  const job = `episodes:${storedChannel}`;
  if (isJobDone(job, date)) return;
  const { start, end } = cycleBounds(date);
  const msgs = messagesBetween(storedChannel, start, end).filter((m) => m.kind !== "system");
  if (!msgs.length) {
    markJobDone(job, date);
    return;
  }
  const [a, b] = names();
  const privateUser = storedChannel.startsWith("ai:") ? storedChannel.slice(3) : "";
  const privateName = privateUser ? subjectLabel(privateUser) : "";
  const out = await chat({
    profile: "task",
    system: [
      "你是大橘，正在把当天的聊天按「话题」切成事件卡片，用于以后语义检索召回。",
      privateName
        ? `这是 ${privateName} 和你（大橘）的私聊频道。正文用真实姓名，不要用「你」这种指代。`
        : `两位主人是 ${a} 和 ${b}。正文用真实姓名，不要用「你/你们」这种称呼。`,
      "一张卡 = 一个完整话题 / 一段互动 / 一个具体决定。话题穿插时按话题归卡，不要按时间机械切分。",
      "一日 3~12 张卡；全天纯寒暄（晚安/嗯/表情包）无实质内容就输出空数组，不要硬凑。",
      "每张卡 6 个字段：",
      "- title：一句话标题 ≤40 字，能让人秒懂这张卡讲什么",
      "- summary：≤80 字概括来龙去脉，要能脱离上下文独立理解，不要用「今天/这次」等短期词",
      "- key_points：3~6 条短句要点，每条 25~60 字，写清触发点-双方反应-结果",
      "- mood：那段话题里两人的情绪状态，一句话",
      "- conclusion：这轮话题是否收尾——自然结束/达成共识写「已收尾」；被打断/没结论写「未收尾」；有具体结果就写「约定 XXX」",
      "- keywords：3~8 个可检索关键词，逗号分隔",
      "不要评判谁对谁错、不要复述伤人的原话、不要写挑拨关系的判断。",
      '只输出 JSON：{"cards":[{...}]}。没有卡片就输出 {"cards":[]}。',
    ].join("\n"),
    user: `日期：${date}\n当天聊天记录（已压缩、按时间顺序）：\n${compactLines(msgs).slice(-18000)}`,
    gen: GEN.episodes,
  });
  const parsed = extractJson<{ cards?: RawCard[] }>(out);
  if (!parsed || !Array.isArray(parsed.cards)) return; // 失败不标记，下次补跑

  deleteEpisodesByDate(storedChannel, date); // 重跑安全
  for (const card of parsed.cards.slice(0, 20)) {
    if (!card?.title) continue;
    await addEpisode({
      channel: storedChannel,
      date,
      title: String(card.title),
      summary: String(card.summary ?? ""),
      keyPoints: Array.isArray(card.key_points) ? card.key_points.map((p) => String(p)) : [],
      mood: String(card.mood ?? ""),
      conclusion: String(card.conclusion ?? ""),
      keywords: Array.isArray(card.keywords) ? card.keywords.join(",") : String(card.keywords ?? ""),
    });
  }
  markJobDone(job, date);
}

// ─── 3. 事实收口 ─────────────────────────────────────────────────────────

interface Verdict {
  id?: string;
  action?: string;
  text?: string;
  category?: string;
  subject?: string;
  importance?: number;
  mergeWithId?: string;
}

function similarActiveFacts(fresh: Fact, active: Fact[]): Array<{ fact: Fact; score: number }> {
  if (!fresh.vector) return [];
  return active
    .filter((a) => a.vector)
    .map((a) => ({ fact: a, score: similarity(fresh.vector!, a.vector!) }))
    .filter((x) => x.score >= 0.7)
    .sort((x, y) => y.score - x.score)
    .slice(0, 3);
}

async function consolidateFacts(date: string): Promise<void> {
  if (isJobDone("consolidate", date)) return;
  const freshFacts = listFacts({ status: "fresh", limit: 40 });
  if (!freshFacts.length) {
    markJobDone("consolidate", date);
    return;
  }
  const activeFacts = listFacts({ status: "active", limit: 2000 });
  const categories = CATEGORIES.map((c) => `${c.key}（${c.label}）`).join("、");
  const lines = freshFacts.map((f) => {
    const sims = similarActiveFacts(f, activeFacts)
      .map((s) => `{id:${s.fact.id}, 内容:${factLine(s.fact)}, 相似度:${s.score.toFixed(2)}}`)
      .join("；");
    return `- {id:${f.id}, 分类:${f.category}, 主语:${subjectLabel(f.subject)}, 内容:${f.text}}${sims ? ` | 相似已有：${sims}` : ""}`;
  }).join("\n");

  const out = await chat({
    profile: "task",
    system: [
      "你是大橘，正在做夜间记忆收口：白天从聊天里提取的新事实（fresh），要逐条裁决进长期记忆库。",
      "长期记忆库只保存以后会反复有用的稳定事实；最近剧情、当天情绪、一次性玩笑、还没稳定的安排，应丢弃。",
      "对每条 fresh 给一个动作（每个 id 只能出现一次）：",
      "- keep：值得长期记住且不重复。可顺带把 text 改得更准确、修正 category/subject、给 importance。",
      "- merge：和某条「相似已有」说的是同一件事或明确更新。mergeWithId 必须指向相似已有的 id；新说法更准就用 text 给出合并后的表述。",
      "- discard：一次性、过几天就没意义、证据不足、主语不清、带评判/挑拨风险，或只是弱重复。",
      `category 只能从这些里选：${categories}。`,
      "importance：纪念日、健康风险、核心雷区、重要约定给 4-5；一般偏好/习惯给 3；弱观察给 1-2。",
      '只输出 JSON 数组：[{"id":"...","action":"keep|merge|discard","text":"可选","category":"可选","subject":"可选","importance":3,"mergeWithId":"merge时必填"}]',
    ].join("\n"),
    user: `今天的 fresh 事实：\n${lines}`,
    gen: GEN.consolidateFacts,
  });
  const verdicts = extractJson<Verdict[]>(out);
  if (!Array.isArray(verdicts)) return; // 失败不标记，fresh 保留，下次重跑幂等

  const seen = new Set<string>();
  for (const v of verdicts) {
    const id = String(v?.id ?? "");
    if (!id || seen.has(id) || !freshFacts.some((f) => f.id === id)) continue;
    seen.add(id);
    if (v.action === "discard") {
      deleteFact(id);
    } else if (v.action === "merge" && v.mergeWithId) {
      // 合并：更新旧事实（可带新表述），删除 fresh。
      await updateFact(String(v.mergeWithId), {
        text: v.text,
        category: v.category,
        subject: v.subject,
        importance: v.importance,
      });
      deleteFact(id);
    } else {
      await updateFact(id, {
        text: v.text,
        category: v.category,
        subject: v.subject,
        importance: v.importance,
        status: "active",
      });
    }
  }
  // 模型漏裁决的 fresh 直接转正（宁可多记，下次收口还能再裁）。
  for (const f of freshFacts) {
    if (!seen.has(f.id)) await updateFact(f.id, { status: "active" });
  }
  markJobDone("consolidate", date);
}

// ─── 4. 短期记忆重写 ─────────────────────────────────────────────────────

async function rewriteShortTerm(date: string): Promise<void> {
  if (isJobDone("short-term", date)) return;
  const oldShort = getDoc("short-term");
  const digests: string[] = [];
  for (let i = 0; i < 3; i += 1) {
    const d = addDays(date, -i);
    const text = getDoc(`digest:${d}`);
    if (text) digests.push(`## ${d}\n${text.slice(0, 4000)}`);
  }
  if (!digests.length && !oldShort) {
    markJobDone("short-term", date);
    return;
  }
  const longFacts = listFacts({ status: "active", limit: 120 }).map((f) => `- ${factLine(f)}`).join("\n");

  const out = await chat({
    profile: "task",
    system: [
      "你是大橘，正在维护自己的短期记忆——「最近一周发生了什么、哪些情绪还在延续」的工作记忆，不是长期事实库。",
      "如果某个稳定事实已经在【长期事实库摘录】里出现，短期记忆不要重复解释它本身；只记录它最近如何被触发、更新或仍未解决。",
      "【格式——严格照这个结构写】",
      "# 大橘短期记忆（更新于 " + date + "）",
      "",
      "## 本周基调",
      "一到两句话概括这几天整体状态。",
      "",
      "## 每日细节",
      "### M月D日",
      "- 短句要点（一行一件事），每天 3~6 条，按时间线和重要性排列",
      "- 有情绪波动单独一条：谁的情绪、因为什么、有没有收尾",
      "",
      "## 待关注",
      "- 还没解决/需要跟进的事，一条一行",
      "",
      "超过一周、已解决或已沉淀进长期库的内容整段删掉。全文不超过 3800 字。",
      "正文用真实名字，不要「你/你们」。不知道结果就写「待确认」，不要虚构。不写挑拨关系的判断。",
      "直接输出 Markdown 全文，不要 JSON、不要解释、不要代码块标记。",
    ].join("\n"),
    user: [
      `整理日期：${date}`,
      longFacts ? `长期事实库摘录（只作参照避免重复）：\n${longFacts}` : "",
      oldShort ? `旧短期记忆：\n${oldShort}` : "旧短期记忆：（空）",
      digests.length ? `最近几天的详细日记：\n${digests.join("\n\n")}` : "",
    ].filter(Boolean).join("\n\n"),
    gen: GEN.shortTermRewrite,
  });
  const next = out?.trim().replace(/^```(?:markdown|md)?\s*/i, "").replace(/\s*```$/i, "").trim();
  if (!next) return;
  // 异常缩水保护：旧内容较长而新内容骤短 → 疑似 LLM 损坏，不覆盖。
  if (oldShort.length > 400 && next.length < Math.min(200, oldShort.length * 0.34)) return;
  setDoc("short-term", next);
  markJobDone("short-term", date);
}

// ─── 5. 人物卡 ×2 + 关系卡 ───────────────────────────────────────────────

async function refreshProfileCards(date: string): Promise<void> {
  if (isJobDone("profiles", date)) return;
  const list = accounts();
  if (list.length < 2) return;
  // 只喂「底牌级」素材：高重要度事实 + 全部雷区，不灌全库（防卡片写成流水账）。
  const seen = new Set<string>();
  const curated: Fact[] = [];
  for (const f of listFacts({ status: "active", minImportance: MEMORY.importantFactMin, limit: MEMORY.importantFactLimit })) {
    seen.add(f.id);
    curated.push(f);
  }
  for (const f of listFacts({ status: "active", limit: 500 })) {
    if (f.category === "boundary" && !seen.has(f.id)) curated.push(f);
  }
  const factLines = curated.map((f) => `- ${factLine(f)}`).join("\n");
  const shortTerm = getDoc("short-term").slice(0, MEMORY.shortTermMax);
  const recentDigest = getDoc(`digest:${date}`).slice(0, 2500);

  const out = await chat({
    profile: "task",
    system: [
      "你是大橘，正在把自己此刻对两位主人的印象写成三张卡片：每位主人一张 + 一张两人关系卡。",
      "卡片每天重写——记录的是「这个人现在大概是什么样、这段关系现在处于什么状态」，不是传记。只能根据给的材料写，不要编造。",
      "每张人物卡按七个小标题分段（缺素材的段跳过，不要硬凑），每段一两句：",
      "性格底色 / 核心偏好 / 雷区 / 沟通模式 / 爱的语言 / 近期关注 / 当前心气",
      "关系卡写五六句：现在是什么状态、当前的主线矛盾或核心温暖点、和解或靠近的模式。",
      "严格排除鸡毛蒜皮：具体吃了什么、某次买了什么，不进卡。每张 ≤400 字。",
      `只输出 JSON：{"profiles":{"${list[0].username}":"人物卡文本","${list[1].username}":"人物卡文本"},"relationship":"关系卡文本"}`,
    ].join("\n"),
    user: [
      `两位主人：${list.map((a) => `${a.username}（昵称 ${a.name}）`).join("、")}`,
      factLines ? `【重要事实（已筛过的底牌）】\n${factLines}` : "",
      shortTerm ? `【短期记忆（只用来把握近况）】\n${shortTerm}` : "",
      recentDigest ? `【最近的详细日记（同上）】\n${recentDigest}` : "",
      "请生成/更新三张卡片。信息不足的部分宁可留白，也不要编。",
    ].filter(Boolean).join("\n\n"),
    gen: GEN.profileCards,
  });
  const parsed = extractJson<{ profiles?: Record<string, string>; relationship?: string }>(out);
  if (!parsed || typeof parsed !== "object") return;
  let wrote = false;
  for (const a of list) {
    const text = parsed.profiles?.[a.username]?.trim();
    if (text) {
      setDoc(`profile:${a.username}`, text.slice(0, 1500));
      wrote = true;
    }
  }
  const rel = (parsed.relationship ?? parsed.profiles?.relationship ?? "").trim();
  if (rel) {
    setDoc("relationship", rel.slice(0, 1500));
    wrote = true;
  }
  if (wrote) markJobDone("profiles", date);
}

// ─── 今日心情（懒生成，首次应答时触发）──────────────────────────────────

const MOOD_FALLBACKS = [
  "今天有点懒洋洋的，晒着太阳不太想动，说话可能比平时更简短。",
  "今天精神头不错，尾巴摇得勤，比平时更愿意搭话。",
  "今天有点傲娇上头，嘴上不饶人，但其实盯得比谁都紧。",
  "今天格外黏人一点，想多听两位主人说说话。",
  "今天状态平平，佛系待机，有事叫我。",
];

let moodGenerating: Promise<string> | null = null;

export async function ensureDailyMood(): Promise<string> {
  const key = `mood:${cycleDate()}`;
  const cached = getDoc(key);
  if (cached) return cached;
  if (moodGenerating) return moodGenerating;
  moodGenerating = (async () => {
    let mood = "";
    if (aiEnabled()) {
      const yesterdayDigest = getDoc(`digest:${addDays(cycleDate(), -1)}`).slice(0, 1500);
      const out = await chat({
        profile: "task",
        system: [
          "你是大橘。现在是新的一天开始，给自己定一个今天的心情底色——一句话，30 字以内。",
          "写今天整体是什么状态/语气倾向（慵懒、来劲、傲娇、柔软、佛系…任选或组合），可以受昨天发生的事影响。",
          "只输出这一句话本身，不要引号不要解释。",
        ].join("\n"),
        user: yesterdayDigest ? `昨天发生的事（日记节选）：\n${yesterdayDigest}\n\n今天的心情是？` : "昨天没什么特别记录。今天的心情是？",
        gen: GEN.dailyMood,
      });
      mood = (out ?? "").trim().split("\n")[0].slice(0, 60);
    }
    if (!mood) mood = MOOD_FALLBACKS[Math.floor(Math.random() * MOOD_FALLBACKS.length)];
    setDoc(key, mood);
    return mood;
  })().finally(() => {
    moodGenerating = null;
  });
  return moodGenerating;
}

// ─── 调度 ────────────────────────────────────────────────────────────────

let maintaining = false;

export async function runDailyMaintenance(): Promise<void> {
  if (maintaining || !aiEnabled()) return;
  maintaining = true;
  const yesterday = addDays(cycleDate(), -1);
  try {
    const channels = ["couple", ...accounts().map((a) => `ai:${a.username}`)];
    await generateDigest(yesterday).catch((e) => console.warn("[ai] digest 失败:", e?.message ?? e));
    for (const ch of channels) {
      await generateEpisodes(ch, yesterday).catch((e) => console.warn(`[ai] episodes(${ch}) 失败:`, e?.message ?? e));
    }
    await consolidateFacts(yesterday).catch((e) => console.warn("[ai] 事实收口失败:", e?.message ?? e));
    await rewriteShortTerm(yesterday).catch((e) => console.warn("[ai] 短期记忆失败:", e?.message ?? e));
    await refreshProfileCards(yesterday).catch((e) => console.warn("[ai] 人物卡失败:", e?.message ?? e));
    await ensureDailyMood().catch(() => {});
    // 用户可见的每日内容：大橘日记（昨日）+ 今日推荐。
    const daily = await import("./dailyContent");
    await daily.generateDiary(yesterday).catch((e) => console.warn("[ai] 日记失败:", e?.message ?? e));
    await daily.ensureRecommendation(cycleDate()).catch((e) => console.warn("[ai] 推荐失败:", e?.message ?? e));
  } finally {
    maintaining = false;
  }
}

export function startScheduler(): void {
  // 启动 30 秒后补跑一次（服务错过切日时间点也能补齐昨日整理）。
  setTimeout(() => {
    runDailyMaintenance().catch(() => {});
  }, 30 * 1000);

  let lastRun = "";
  setInterval(() => {
    const bj = beijingParts();
    const today = cycleDate();
    if (bj.hour === DAY_ROLLOVER_HOUR && bj.minute <= 5 && lastRun !== today) {
      lastRun = today;
      runDailyMaintenance().catch(() => {});
    }
  }, 60 * 1000);
}
