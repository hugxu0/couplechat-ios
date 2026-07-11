import type { MessageRow } from "../../db";

export type ChatSearchMode = "hybrid" | "all" | "any";

export interface RankedChatMessage {
  row: MessageRow;
  matchedTerms: string[];
  relevance: number;
}

function normalize(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase("zh-CN").replace(/\s+/g, "").trim();
}

function isCjk(value: string): boolean {
  return /[\u3400-\u9fff]/u.test(value);
}

function segmentChunk(chunk: string): string[] {
  type SegmenterInstance = { segment(value: string): Iterable<{ segment: string; isWordLike?: boolean }> };
  type SegmenterConstructor = new (locales?: string | string[], options?: { granularity?: string }) => SegmenterInstance;
  const Segmenter = (Intl as unknown as { Segmenter?: SegmenterConstructor }).Segmenter;
  if (!Segmenter) return [chunk];
  try {
    const segmenter = new Segmenter("zh-CN", { granularity: "word" });
    return Array.from(segmenter.segment(chunk))
      .map((item) => item.segment)
      .filter((item) => item.length >= 2);
  } catch {
    return [chunk];
  }
}

// 将查询拆成可检索词。语义扩展由 Agent 通过 alternatives 提供；搜索内核不维护领域词典。
export function searchTerms(query: string): string[] {
  const chunks = query
    .normalize("NFKC")
    .split(/[\s,，、;；|/]+/u)
    .map((item) => item.trim())
    .filter(Boolean);
  const terms: string[] = [];
  const add = (value: string) => {
    const term = normalize(value);
    if (term.length < 2 || terms.includes(term)) return;
    terms.push(term);
  };

  for (const chunk of chunks) {
    const segmented = segmentChunk(chunk);
    if (isCjk(chunk) && segmented.length > 1) {
      segmented.forEach(add);
    } else {
      add(chunk);
      segmented.forEach(add);
    }
  }
  return terms.slice(0, 8);
}

function rankOne(
  row: MessageRow,
  terms: string[],
  queries: string[],
  inverseFrequency: Map<string, number>,
): RankedChatMessage | null {
  const text = normalize(row.text);
  const matchedTerms = terms.filter((term) => text.includes(term));
  if (!matchedTerms.length) return null;
  const coverage = matchedTerms.length / terms.length;
  const phraseBonus = queries.some((query) => {
    const phrase = normalize(query);
    return phrase.length >= 2 && text.includes(phrase);
  }) ? 2 : 0;
  const relevance = matchedTerms.reduce(
    (sum, term) => sum + (inverseFrequency.get(term) ?? 1) * Math.min(term.length, 8),
    0,
  ) + coverage * 5
    + phraseBonus;
  return { row, matchedTerms, relevance };
}

// all 先尝试同一条消息全命中；没有结果时自动放宽到 hybrid。
export function rankChatSearchRows(
  rows: MessageRow[],
  query: string | string[],
  requestedMode: ChatSearchMode = "hybrid",
  limit = 12,
): { terms: string[]; effectiveMode: ChatSearchMode; relaxed: boolean; hits: RankedChatMessage[] } {
  const queries = (Array.isArray(query) ? query : [query]).map((item) => item.trim()).filter(Boolean);
  const terms = searchTerms(queries.join(" "));
  if (!terms.length) return { terms: [], effectiveMode: requestedMode, relaxed: false, hits: [] };
  const inverseFrequency = new Map<string, number>();
  for (const term of terms) {
    const documents = rows.reduce((count, row) => count + (normalize(row.text).includes(term) ? 1 : 0), 0);
    inverseFrequency.set(term, Math.log((rows.length + 1) / (documents + 1)) + 1);
  }
  const ranked = rows
    .map((row) => rankOne(row, terms, queries, inverseFrequency))
    .filter((item): item is RankedChatMessage => Boolean(item))
    .sort((a, b) => b.relevance - a.relevance || b.row.ts - a.row.ts);
  if (requestedMode !== "all") {
    return { terms, effectiveMode: requestedMode, relaxed: false, hits: ranked.slice(0, limit) };
  }
  const exact = ranked.filter((item) => item.matchedTerms.length === terms.length);
  if (exact.length) return { terms, effectiveMode: "all", relaxed: false, hits: exact.slice(0, limit) };
  return { terms, effectiveMode: "hybrid", relaxed: true, hits: ranked.slice(0, limit) };
}
