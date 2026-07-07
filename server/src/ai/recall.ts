// 静默召回：每次应答都跑。用「当前问题 + 最近几条用户消息」当查询句，
// 一次 embedding 调用同时召回事实 + 事件卡片，低于阈值一条不注入——
// 「记忆感」是常态，token 只在真有相关记忆时花。
// （对比旧版：不再让 LLM 先跑一轮 planContext/retrievalQuery 生成查询词，
//  实测原文拼接对向量检索足够，省两次 LLM 调用、省约 3~5 秒延迟。）

import { embedOne, embeddingEnabled, similarity } from "./embeddings";
import {
  factLine,
  listEpisodes,
  listFacts,
  type Episode,
  type Fact,
} from "./memoryStore";
import { MEMORY } from "./params";

export interface Recalled {
  factsContext: string;
  episodesContext: string;
}

const EMPTY: Recalled = { factsContext: "", episodesContext: "" };

function episodeLine(e: Episode, rich: boolean): string {
  const head = `- ${e.date} · ${e.title}：${e.summary}`;
  if (!rich) return head;
  const pts = e.keyPoints.slice(0, 4).map((p) => `    · ${p}`);
  const tail = e.conclusion ? [`    ↳ ${e.conclusion}`] : [];
  return [head, ...pts, ...tail].join("\n");
}

// channel 传入的是存储频道：记忆主体永远查 couple 的事件卡；
// 私聊（ai:<user>）额外查本人私聊卡片，但私聊卡片绝不进 couple 的回答。
export async function recall(query: string, storedChannel: string): Promise<Recalled> {
  const q = query.trim();
  if (!q) return EMPTY;

  if (!embeddingEnabled()) {
    // 无向量服务：退化为「高重要度事实兜底」，保证雷区/纪念日这类底牌仍然在场。
    const important = listFacts({ status: "active", minImportance: MEMORY.importantFactMin, limit: MEMORY.factTopK });
    return {
      factsContext: important.map((f) => `- ${factLine(f)}`).join("\n"),
      episodesContext: "",
    };
  }

  const vector = await embedOne(q);
  if (!vector) return EMPTY;

  const facts = listFacts({ limit: 2000 })
    .map((f) => ({ f, score: f.vector ? similarity(vector, f.vector) : 0 }))
    .filter((x) => x.score >= MEMORY.factMinScore)
    .sort((a, b) => b.score - a.score)
    .slice(0, MEMORY.factTopK);

  const episodePool = [
    ...listEpisodes("couple"),
    ...(storedChannel.startsWith("ai:") ? listEpisodes(storedChannel) : []),
  ];
  const episodes = episodePool
    .map((e) => ({ e, score: e.vector ? similarity(vector, e.vector) : 0 }))
    .filter((x) => x.score >= MEMORY.episodeMinScore)
    .sort((a, b) => b.score - a.score)
    .slice(0, MEMORY.episodeTopK);

  return {
    factsContext: facts.map((x) => `- ${factLine(x.f)}`).join("\n"),
    // 前 3 张高分卡带要点和结论（卡片里最值钱的因果细节），其余只给标题行控制 token。
    episodesContext: episodes.map((x, i) => episodeLine(x.e, i < 3)).join("\n"),
  };
}

// 无关场景防御：召回失败不影响应答。
export async function recallSafe(query: string, storedChannel: string): Promise<Recalled> {
  try {
    return await recall(query, storedChannel);
  } catch {
    return EMPTY;
  }
}
