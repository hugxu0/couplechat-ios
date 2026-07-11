import { accounts } from "../accounts";
import { compactLines, messagesBetween, recentMessages } from "../conversation/log";
import { searchMemory } from "../memory/store";
import { aiEnabled, chat, extractJson } from "../provider";
import { readRuntimeState, writeRuntimeState } from "../runtimeState";
import { addDays, cycleBounds, cycleDate } from "../time";

const DIARY_GEN = { maxTokens: 1000, temperature: 0.75, timeoutMs: 60_000 };
const RECOMMEND_GEN = { maxTokens: 900, temperature: 0.85, timeoutMs: 45_000 };

export interface Recommendation {
  category: string;
  title: string;
  reason: string;
}

export async function generateDiary(date: string): Promise<void> {
  if (await readRuntimeState(`diary:${date}`)) return;
  const { start, end } = cycleBounds(date);
  const messages = (await messagesBetween("couple", start, end)).filter((message) => message.kind !== "system");
  if (!messages.length || !aiEnabled()) return;
  const output = await chat({
    profile: "task",
    system: [
      "你是大橘，把两位主人昨天的聊天写成一篇他们都能看到的短日记。",
      `两位主人是 ${accounts().map((account) => account.name).join(" 和 ")}。`,
      "只写真实发生的事和情绪变化，不评判、不补充、不复述伤人的原话。用大橘第一人称，150~300 字。",
    ].join("\n"),
    user: compactLines(messages, 180).slice(-16000),
    gen: DIARY_GEN,
  });
  const text = output?.trim();
  if (text) await writeRuntimeState(`diary:${date}`, text.slice(0, 1200));
}

export async function readRecommendation(date: string): Promise<Recommendation | null> {
  try {
    const raw = await readRuntimeState(`recommend:${date}`);
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
    const [memories, recent] = await Promise.all([
      searchMemory({
        query: "",
        layers: ["fact", "state", "relationship", "plan"],
        scopes: ["couple"],
        limit: 30,
      }),
      recentMessages("couple", 40),
    ]);
    const out = await chat({
      profile: "task",
      system: [
        "你是大橘，为两位主人挑一个今天可以共同完成的推荐。",
        `两位主人是 ${accounts().map((account) => account.name).join(" 和 ")}。`,
        "可以推荐美食、观影、活动、音乐或一个小约定。结合可靠记忆和最近聊天，不要臆测。",
        '只输出 JSON：{"category":"美食|观影|活动|音乐|约定","title":"推荐名","reason":"具体理由"}',
      ].join("\n"),
      user: [
        memories.length ? `【相关记忆】\n${memories.map((memory) => `- ${memory.content}`).join("\n")}` : "",
        recent.length ? `【最近聊天】\n${compactLines(recent, 160)}` : "",
        cached ? `上一个推荐是「${cached.title}」，这次换一个。` : "",
        `今天是 ${date}。`,
      ].filter(Boolean).join("\n\n"),
      gen: RECOMMEND_GEN,
    });
    const parsed = extractJson<Recommendation>(out);
    if (!parsed?.title) return cached;
    const recommendation: Recommendation = {
      category: String(parsed.category ?? "推荐").slice(0, 10),
      title: String(parsed.title).slice(0, 60),
      reason: String(parsed.reason ?? "").slice(0, 400),
    };
    await writeRuntimeState(`recommend:${date}`, JSON.stringify(recommendation));
    return recommendation;
  } finally {
    recommending = false;
  }
}

export async function dailyContent() {
  const today = cycleDate();
  const yesterday = addDays(today, -1);
  let diary: { date: string; text: string } | null = null;
  for (let offset = 1; offset <= 7; offset += 1) {
    const date = addDays(today, -offset);
    const text = await readRuntimeState(`diary:${date}`);
    if (text) {
      diary = { date, text };
      break;
    }
  }
  return { today, yesterday, diary, recommend: await readRecommendation(today) };
}
