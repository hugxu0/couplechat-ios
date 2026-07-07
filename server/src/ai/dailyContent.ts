// 面向用户的每日内容：大橘日记（昨日回顾）+ 今日推荐。
// 与 nightly 的内部记忆整理分开——digest 是给大橘自己看的素材，
// 这里的日记是写给两位主人看的成品。

import { getDoc, isJobDone, listFacts, markJobDone, setDoc, factLine, accounts } from "./memoryStore";
import { aiEnabled, chat, extractJson } from "./provider";
import { addDays, cycleDate } from "./time";
import { MEMORY } from "./params";

const DIARY_GEN = { maxTokens: 1000, temperature: 0.78, timeoutMs: 60_000 };
const RECOMMEND_GEN = { maxTokens: 900, temperature: 0.85, timeoutMs: 45_000 };

// ─── 大橘日记（昨日回顾，用户可见）─────────────────────────────────────

export async function generateDiary(date: string): Promise<void> {
  if (await isJobDone("diary", date)) return;
  const digest = await getDoc(`digest:${date}`);
  if (!digest) return; // digest 还没生成（或当天没聊天），等下一轮
  const names = accounts().map((a) => a.name);
  const out = await chat({
    profile: "task",
    system: [
      "你是大橘，一只陪着两位主人的橘猫。现在把昨天的内部记录改写成一篇短日记，两位主人都会看到。",
      `两位主人是 ${names.join(" 和 ")}。`,
      "用大橘的第一人称视角写：像猫窝在旁边看了一天后的碎碎念，温柔、有点慵懒、偶尔带一声喵。",
      "写昨天真实发生的事和情绪流动，2~4 段、全文 150~300 字。",
      "不评判谁对谁错，不复述伤人的原话，不提「记录/数据/系统」这种技术词。",
      "直接输出日记正文，不要标题、不要日期、不要解释。",
    ].join("\n"),
    user: `昨天的内部记录：\n${digest.slice(0, 5000)}`,
    gen: DIARY_GEN,
  });
  const text = out?.trim();
  if (!text) return;
  await setDoc(`diary:${date}`, text.slice(0, 1200));
  await markJobDone("diary", date);
}

// ─── 今日推荐 ────────────────────────────────────────────────────────────

export interface Recommendation {
  category: string;
  title: string;
  reason: string;
}

export async function readRecommendation(date: string): Promise<Recommendation | null> {
  try {
    const raw = await getDoc(`recommend:${date}`);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<Recommendation>;
    if (!parsed.title) return null;
    return {
      category: String(parsed.category ?? "推荐"),
      title: String(parsed.title),
      reason: String(parsed.reason ?? ""),
    };
  } catch {
    return null;
  }
}

let recommending = false;

export async function ensureRecommendation(date: string, force = false): Promise<Recommendation | null> {
  const cached = await readRecommendation(date);
  if (cached && !force) return cached;
  if (!aiEnabled() || recommending) return cached;
  recommending = true;
  try {
    const facts = (await listFacts({ status: "active", limit: 200 }))
      .filter((f) => ["preference", "plan", "event", "relationship"].includes(f.category))
      .slice(0, 40)
      .map((f) => `- ${factLine(f)}`)
      .join("\n");
    const shortTerm = (await getDoc("short-term")).slice(0, MEMORY.shortTermMax);
    const previous = cached ? `上一个推荐是「${cached.title}」，这次换个不同的。` : "";
    const out = await chat({
      profile: "task",
      system: [
        "你是大橘，每天给两位主人挑一个共同推荐：一道菜 / 一部片 / 一个小活动 / 一首歌 / 一个小约定，任选一类。",
        "结合他们的喜好和最近的状态挑：正在闹别扭就推能修复气氛的，异地想念就推能远程一起做的，日常平淡就推点新鲜的。",
        "reason 用大橘的口吻写 2~3 句：为什么今天推这个、和他们最近的事有什么关系。要具体，不要「增进感情」这种空话。",
        '只输出 JSON：{"category":"美食|观影|活动|音乐|约定","title":"推荐名","reason":"推荐理由"}',
      ].join("\n"),
      user: [
        facts ? `【两人的喜好与近况事实】\n${facts}` : "",
        shortTerm ? `【最近一周】\n${shortTerm.slice(0, 2000)}` : "",
        previous,
        `今天是 ${date}，请给出今日推荐。`,
      ].filter(Boolean).join("\n\n"),
      gen: RECOMMEND_GEN,
    });
    const parsed = extractJson<Recommendation>(out);
    if (!parsed?.title) return cached;
    const rec: Recommendation = {
      category: String(parsed.category ?? "推荐").slice(0, 10),
      title: String(parsed.title).slice(0, 60),
      reason: String(parsed.reason ?? "").slice(0, 400),
    };
    await setDoc(`recommend:${date}`, JSON.stringify(rec));
    return rec;
  } finally {
    recommending = false;
  }
}

// ─── 读取汇总（REST 用）─────────────────────────────────────────────────

export async function dailyContent() {
  const today = cycleDate();
  const yesterday = addDays(today, -1);
  // 日记优先给昨天的；昨天没有就往前找最近一篇（最多 7 天）。
  let diary: { date: string; text: string } | null = null;
  for (let i = 1; i <= 7; i += 1) {
    const d = addDays(today, -i);
    const text = await getDoc(`diary:${d}`);
    if (text) {
      diary = { date: d, text };
      break;
    }
  }
  const recommend = await readRecommendation(today);
  return { today, yesterday, diary, recommend };
}
