import { MCPServerStreamableHttp } from "@openai/agents";
import { config } from "../../config";
import { webSearch as mimoWebSearch, type Citation, type SearchResult } from "../provider";
import type { GenProfile } from "../settings";

export type WebSearchSource = "domestic" | "global" | "crosscheck" | "auto";

export interface RoutedSearchResult extends SearchResult {
  provider: "mimo" | "tavily" | "merged";
  fallbackReason?: string;
}

interface TavilySearchItem {
  url?: string;
  title?: string;
  content?: string;
  score?: number;
}

interface TavilyPayload {
  answer?: string | null;
  results?: TavilySearchItem[];
}

const searchCache = new Map<string, { expiresAt: number; value: RoutedSearchResult }>();
const SEARCH_CACHE_TTL_MS = 10 * 60_000;

function tavilyEnabled(): boolean {
  return Boolean(config.tavilyMcpUrl || config.tavilyApiKey);
}

function createTavilyClient(): MCPServerStreamableHttp {
  return new MCPServerStreamableHttp({
    url: config.tavilyMcpUrl || "https://mcp.tavily.com/mcp/",
    name: "Tavily MCP",
    cacheToolsList: true,
    timeout: 45_000,
    requestInit: config.tavilyApiKey
      ? { headers: { Authorization: `Bearer ${config.tavilyApiKey}` } }
      : undefined,
  });
}

function parseRemotePayload(value: unknown): unknown {
  if (!Array.isArray(value)) return value;
  const texts = value.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const block = item as { type?: unknown; text?: unknown };
    return block.type === "text" && typeof block.text === "string" ? [block.text] : [];
  });
  if (texts.length !== 1) return { content: value };
  try {
    return JSON.parse(texts[0]);
  } catch {
    return { content: texts[0] };
  }
}

async function callTavily(toolName: "tavily_search" | "tavily_extract", args: Record<string, unknown>): Promise<unknown> {
  if (!tavilyEnabled()) return null;
  const client = createTavilyClient();
  try {
    await client.connect();
    return parseRemotePayload(await client.callTool(toolName, args));
  } catch (error) {
    console.warn(`[ai] Tavily ${toolName} 失败: ${error instanceof Error ? error.message : String(error)}`);
    return null;
  } finally {
    await client.close().catch(() => {});
  }
}

async function tavilySearch(query: string): Promise<RoutedSearchResult | null> {
  const payload = await callTavily("tavily_search", {
    query,
    max_results: 5,
    search_depth: "basic",
    include_raw_content: false,
  }) as TavilyPayload | null;
  const rows = (payload?.results ?? []).filter((item) => item.url);
  if (!rows.length && !payload?.answer) return null;
  const annotations: Citation[] = rows.map((item) => ({
    url: String(item.url),
    title: String(item.title || item.url),
    site_name: (() => {
      try { return new URL(String(item.url)).hostname; } catch { return undefined; }
    })(),
    summary: String(item.content ?? "").slice(0, 600),
  }));
  const snippets = rows.map((item, index) =>
    `${index + 1}. ${item.title || item.url}\n${String(item.content ?? "").slice(0, 1800)}`,
  );
  return {
    content: [payload?.answer?.trim(), ...snippets].filter(Boolean).join("\n\n"),
    annotations,
    provider: "tavily",
  };
}

async function mimoSearch(query: string, gen: GenProfile): Promise<RoutedSearchResult | null> {
  const result = await mimoWebSearch(query, gen);
  return result ? { ...result, provider: "mimo" } : null;
}

function goodEnough(result: RoutedSearchResult | null): result is RoutedSearchResult {
  return Boolean(result && result.content.trim().length >= 60 && result.annotations.length > 0);
}

function mergeResults(a: RoutedSearchResult | null, b: RoutedSearchResult | null): RoutedSearchResult | null {
  if (!a) return b;
  if (!b) return a;
  const annotations: Citation[] = [];
  for (const citation of [...a.annotations, ...b.annotations]) {
    if (!annotations.some((existing) => existing.url === citation.url)) annotations.push(citation);
  }
  return {
    content: [`【${a.provider}】\n${a.content}`, `【${b.provider}】\n${b.content}`].join("\n\n"),
    annotations: annotations.slice(0, 8),
    provider: "merged",
  };
}

async function searchProvider(
  provider: "mimo" | "tavily",
  query: string,
  gen: GenProfile,
): Promise<RoutedSearchResult | null> {
  return provider === "mimo" ? mimoSearch(query, gen) : tavilySearch(query);
}

export async function routedWebSearch(
  query: string,
  source: WebSearchSource,
  gen: GenProfile,
): Promise<RoutedSearchResult | null> {
  const normalizedQuery = query.replace(/\s+/g, " ").trim();
  const cacheKey = `${source}:${normalizedQuery.toLocaleLowerCase()}`;
  const cached = searchCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) return cached.value;

  let result: RoutedSearchResult | null;
  if (source === "crosscheck") {
    const [mimo, tavily] = await Promise.all([
      mimoSearch(normalizedQuery, gen),
      tavilySearch(normalizedQuery),
    ]);
    result = mergeResults(mimo, tavily);
  } else {
    const order: Array<"mimo" | "tavily"> = source === "global"
      ? ["tavily", "mimo"]
      : ["mimo", "tavily"];
    const primary = await searchProvider(order[0], normalizedQuery, gen);
    if (goodEnough(primary)) {
      result = primary;
    } else {
      const fallback = await searchProvider(order[1], normalizedQuery, gen);
      result = fallback
        ? { ...fallback, fallbackReason: `${order[0]}_unavailable_or_low_quality` }
        : primary;
    }
  }

  if (result) searchCache.set(cacheKey, { expiresAt: Date.now() + SEARCH_CACHE_TTL_MS, value: result });
  return result;
}

export async function extractWebPages(
  urls: string[],
  query?: string,
): Promise<{ provider: "tavily"; pages: Array<{ url: string; title: string; content: string }>; unavailable?: boolean }> {
  const payload = await callTavily("tavily_extract", {
    urls: urls.slice(0, 3),
    extract_depth: "basic",
    format: "markdown",
    query: query ?? "",
  }) as { results?: Array<{ url?: string; title?: string; raw_content?: string; content?: string }> } | null;
  const pages = (payload?.results ?? []).map((item) => ({
    url: String(item.url ?? ""),
    title: String(item.title ?? item.url ?? ""),
    content: String(item.raw_content ?? item.content ?? "").slice(0, 10_000),
  })).filter((item) => item.url && item.content);
  return { provider: "tavily", pages, ...(pages.length ? {} : { unavailable: true }) };
}
