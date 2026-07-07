// 增量事实提取：couple 频道每积累 N 条用户文本消息，从增量聊天里提取稳定事实
// 入库（status='fresh'，夜间收口转正）。游标存 ai_docs，重启不丢、不重复扫。
// 启动后首次触发时游标快进到当前最新消息（放弃重启前未扫完的部分，换取绝不重复）。

import { compactLines, messagesAfter, latestTs } from "./chatLog";
import { addFact, accounts, CATEGORIES, factLine, getDoc, listFacts, setDoc } from "./memoryStore";
import { chat, extractJson } from "./provider";
import { GEN, PACE } from "./params";

const CURSOR_KEY = "cursor:fact-scan";

let pendingCount = 0;
let running = false;

interface ExtractedFact {
  subject?: string;
  text?: string;
  category?: string;
  importance?: number;
}

function buildSystem(): string {
  const categories = CATEGORIES.map((c) => `${c.key}（${c.label}）`).join("、");
  const subjects = accounts().map((a) => `${a.username}=${a.name}`).join("、");
  return [
    "你负责为情侣聊天助手「大橘」提取长期记忆。长期记忆是一条条可检索的稳定事实，不是聊天总结。",
    "最近发生的剧情、当天情绪、一次性争执、某场比赛/游戏结果，交给短期记忆；只有以后多次对话仍会用上的信息才进长期事实库。",
    "优先保存：基本个人信息（年龄、生日、所在城市、家乡、职业/学校、家庭情况）、稳定的喜好和口味、长期习惯和作息、健康体质、雷区边界、明确约定和纪念日、重要人物和事件、反复出现且已经稳定的关系相处模式。",
    "如果用户明确说「记住/记得」，且内容属于可长期使用的信息，通常应该保存。",
    "不要保存：临时情绪宣泄、玩笑、争吵里的单方面评判、当天吃了什么/玩了什么、一次性赌约细节、还没稳定的近况。",
    "不要把「谁对谁错」写进事实，不要写会挑拨关系的判断；只写未来帮助理解和照顾他们的中性事实。",
    "一条记忆只写一个事实；一句话里有两件事就拆成两条。",
    "每条记忆输出四个字段：",
    `- subject：这件事是谁的。用 username：${subjects}；两人共同的（约定/纪念日/共同规则）写 both。`,
    '- text：事实本身，简洁、可长期复用、可独立理解；主语已在 subject 里，text 不要重复人名，如 subject=xu, text="不吃香菜"。',
    `- category：${categories}，选最贴的一个。`,
    "- importance：1-5。纪念日、健康风险、核心雷区、重要约定给 4-5；一般偏好/习惯给 3；弱观察给 1-2。",
    "下面【已记下的记忆】是之前已经提取过的；意思相同/重叠的不要再写，只输出真正新增的。",
    '只输出 JSON：{"memories":[{"subject":"xu","text":"...","category":"preference","importance":3}]}',
    '没有值得保存的就输出 {"memories":[]}',
  ].join("\n");
}

async function scan(): Promise<void> {
  const cursorRaw = Number(getDoc(CURSOR_KEY));
  // 首次触发：游标快进到最新消息，跳过历史（历史归夜间事件卡管）。
  if (!Number.isFinite(cursorRaw) || cursorRaw <= 0) {
    setDoc(CURSOR_KEY, String(latestTs("couple") || Date.now()));
    return;
  }

  const increment = messagesAfter("couple", cursorRaw, 200);
  const userLines = compactLines(increment.filter((m) => m.kind === "user" && m.type === "text" && m.text.trim()));
  if (!userLines) {
    if (increment.length) setDoc(CURSOR_KEY, String(increment[increment.length - 1].ts));
    return;
  }

  // 当日 fresh 事实喂给 LLM 做语义去重（弥补入库查重漏掉的措辞变体）。
  const existing = listFacts({ status: "fresh", limit: 80 }).map((f) => `- ${factLine(f)}`).join("\n");

  const out = await chat({
    profile: "task",
    system: buildSystem(),
    user: [
      existing ? `【已记下的记忆】\n${existing}` : "",
      `【本次新聊天】\n${userLines}`,
      "请只从【本次新聊天】里提取新记忆，最多 5 条。",
    ].filter(Boolean).join("\n\n"),
    gen: GEN.extractFacts,
  });
  const parsed = extractJson<{ memories?: ExtractedFact[] }>(out);
  for (const item of (parsed?.memories ?? []).slice(0, 5)) {
    if (!item?.text) continue;
    await addFact({
      subject: item.subject,
      text: item.text,
      category: item.category,
      importance: item.importance,
      status: "fresh",
    });
  }
  setDoc(CURSOR_KEY, String(increment[increment.length - 1].ts));
}

// couple 频道每条用户文本消息调一次；攒够 N 条才真正跑（互斥，静默失败）。
export function onCoupleUserMessage(): void {
  pendingCount += 1;
  if (pendingCount < PACE.factScanEveryMessages || running) return;
  pendingCount = 0;
  running = true;
  scan()
    .catch((error) => console.warn("[ai] 事实提取失败:", error instanceof Error ? error.message : error))
    .finally(() => {
      running = false;
    });
}
