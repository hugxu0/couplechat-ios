// LLM 客户端：OpenAI 兼容 /chat/completions + Anthropic 原生 /messages 双协议。
// 失败/未配置一律返回 null，调用方自行兜底——用户永远不该看到堆栈。

import { config, type AiProvider } from "../config";
import { responsesReasoningSettings, type GenProfile } from "./settings";

export type ChatProfile = "chat" | "task";

export function aiEnabled(): boolean {
  return Boolean(config.ai.chat || config.ai.task);
}

function providerFor(profile: ChatProfile): AiProvider | undefined {
  return config.ai[profile] ?? config.ai.chat ?? config.ai.task;
}

function isClaudeModel(model: string) {
  return /^claude-/i.test(model);
}

function responsesText(data: unknown): string | null {
  if (!data || typeof data !== "object") return null;
  const response = data as {
    output_text?: unknown;
    output?: Array<{ content?: Array<{ text?: unknown }> }>;
  };
  if (typeof response.output_text === "string" && response.output_text.trim()) {
    return response.output_text.trim();
  }
  const text = (response.output ?? [])
    .flatMap((item) => item.content ?? [])
    .map((content) => typeof content.text === "string" ? content.text : "")
    .filter(Boolean)
    .join("\n")
    .trim();
  return text || null;
}

interface ChatArgs {
  profile: ChatProfile;
  system: string;
  user: string;
  gen: GenProfile;
}

async function logHttpFailure(scope: string, res: Response): Promise<void> {
  let detail = "";
  try {
    detail = (await res.text()).replace(/\s+/g, " ").trim().slice(0, 400);
  } catch {
    // 读取错误响应失败时，状态码本身仍足够用于定位。
  }
  const retryAfter = res.headers.get("retry-after");
  console.warn(
    `[ai] ${scope} HTTP ${res.status}` +
      (retryAfter ? ` retry-after=${retryAfter}` : "") +
      (detail ? ` body=${detail}` : ""),
  );
}

// Anthropic 原生 Messages API。system 标 cache_control:ephemeral：
// 人设+格式说明每次调用都不变，连续对话能吃到提示词缓存（约 1/10 计费）。
async function chatAnthropic(p: AiProvider, args: ChatArgs, signal: AbortSignal): Promise<string | null> {
  const res = await fetch(`${p.baseUrl.replace(/\/$/, "")}/messages`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": p.apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: p.model,
      max_tokens: args.gen.maxTokens,
      temperature: args.gen.temperature,
      system: [{ type: "text", text: args.system, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: args.user }],
    }),
    signal,
  });
  if (!res.ok) {
    await logHttpFailure(`${args.profile} anthropic`, res);
    return null;
  }
  const data = (await res.json()) as {
    content?: Array<{ type: string; text?: string }>;
    stop_reason?: string;
  };
  const text = (data.content ?? [])
    .filter((b) => b.type === "text" && b.text)
    .map((b) => b.text)
    .join("");
  const content = text.trim() || null;
  if (!content) console.warn(`[ai] ${args.profile} anthropic 空响应 stop_reason=${data.stop_reason ?? "unknown"}`);
  return content;
}

async function chatOpenAi(p: AiProvider, args: ChatArgs, signal: AbortSignal): Promise<string | null> {
  const res = await fetch(`${p.baseUrl.replace(/\/$/, "")}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${p.apiKey}` },
    body: JSON.stringify({
      model: p.model,
      max_tokens: args.gen.maxTokens,
      temperature: args.gen.temperature,
      messages: [
        { role: "system", content: args.system },
        { role: "user", content: args.user },
      ],
    }),
    signal,
  });
  if (!res.ok) {
    await logHttpFailure(args.profile, res);
    return null;
  }
  const data = (await res.json()) as {
    choices?: Array<{ message?: { content?: string }; finish_reason?: string }>;
  };
  const content = data.choices?.[0]?.message?.content;
  const text = content ? String(content).trim() || null : null;
  if (!text) console.warn(`[ai] ${args.profile} 空响应 finish_reason=${data.choices?.[0]?.finish_reason ?? "unknown"}`);
  return text;
}

async function chatOpenAiResponses(p: AiProvider, args: ChatArgs, signal: AbortSignal): Promise<string | null> {
  const res = await fetch(`${p.baseUrl.replace(/\/$/, "")}/responses`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${p.apiKey}` },
    body: JSON.stringify({
      model: p.model,
      instructions: args.system,
      input: args.user,
      max_output_tokens: args.gen.maxTokens,
      temperature: args.gen.temperature,
      reasoning: responsesReasoningSettings(args.gen.reasoningEffort ?? p.reasoningEffort),
      store: false,
    }),
    signal,
  });
  if (!res.ok) {
    await logHttpFailure(`${args.profile} responses`, res);
    return null;
  }
  const text = responsesText(await res.json());
  if (!text) console.warn(`[ai] ${args.profile} responses 空响应`);
  return text;
}

export async function chat(args: ChatArgs): Promise<string | null> {
  const provider = providerFor(args.profile);
  if (!provider) return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), args.gen.timeoutMs ?? 30_000);
  try {
    if (provider.apiMode === "anthropic" || isClaudeModel(provider.model)) {
      return await chatAnthropic(provider, args, controller.signal);
    }
    if (provider.apiMode === "responses") {
      const primary = await chatOpenAiResponses(provider, args, controller.signal);
      if (primary) return primary;
      if (controller.signal.aborted) return null;
      console.warn(`[ai] ${args.profile} Responses 不可用，回退 Chat Completions`);
    }
    return await chatOpenAi(provider, args, controller.signal);
  } catch (error) {
    const name = error instanceof Error ? error.name : "";
    console.warn(`[ai] ${args.profile} ${name === "AbortError" ? "超时" : `失败: ${error instanceof Error ? error.message : error}`}`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// 识图：OpenAI 兼容的多模态接口，支持一次联合分析最多 9 张图片。
export async function describeImages(
  suppliedUrls: string[],
  gen: GenProfile,
  prompt = "按顺序观察这些图片，说明每张图与当前问题有关的内容，并在需要时比较它们。不能确定的细节要明确说明。",
): Promise<string | null> {
  const imageUrls = [...new Set(suppliedUrls.filter(Boolean))].slice(0, 9);
  if (!imageUrls.length) return null;
  const p = config.aiVision;
  if (!p) return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), gen.timeoutMs ?? 30_000);
  try {
    if (p.apiMode === "responses") {
      const res = await fetch(`${p.baseUrl.replace(/\/$/, "")}/responses`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${p.apiKey}` },
        body: JSON.stringify({
          model: p.model,
          input: [{
            role: "user",
            content: [
              { type: "input_text", text: prompt },
              ...imageUrls.map((imageUrl) => ({ type: "input_image", image_url: imageUrl })),
            ],
          }],
          max_output_tokens: gen.maxTokens,
          temperature: gen.temperature,
          reasoning: responsesReasoningSettings(p.reasoningEffort),
          store: false,
        }),
        signal: controller.signal,
      });
      if (!res.ok) {
        await logHttpFailure("vision responses", res);
        return null;
      }
      return responsesText(await res.json());
    }
    const res = await fetch(`${p.baseUrl.replace(/\/$/, "")}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${p.apiKey}` },
      body: JSON.stringify({
        model: p.model,
        max_tokens: gen.maxTokens,
        temperature: gen.temperature,
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: prompt },
              ...imageUrls.map((imageUrl) => ({ type: "image_url", image_url: { url: imageUrl } })),
            ],
          },
        ],
      }),
      signal: controller.signal,
    });
    if (!res.ok) {
      await logHttpFailure("vision", res);
      return null;
    }
    const data = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const content = data.choices?.[0]?.message?.content;
    return content ? String(content).trim() || null : null;
  } catch (error) {
    const name = error instanceof Error ? error.name : "";
    console.warn(`[ai] vision ${name === "AbortError" ? "超时" : `失败: ${error instanceof Error ? error.message : error}`}`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export async function describeImage(
  imageUrl: string,
  gen: GenProfile,
  prompt = "用一两句话简短描述这张图片的内容，中文回答。",
): Promise<string | null> {
  return describeImages([imageUrl], gen, prompt);
}

// 联网搜索：复用 AI_VISION_*（同一个 MiMo 账号既能识图也能联网），
// tools:[{type:"web_search",...}] 是 MiMo 私有格式，文档：
// https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/text-generation/tool-calling/web-search
// 未配置/调用失败都返回 null，调用方按「如实说查不到」兜底，不编造内容。
// 返回 { content, annotations }，annotations 是 MiMo 返回的来源引用列表（供前端展示来源卡片）。

export interface Citation {
  url: string;
  title: string;
  site_name?: string;
  summary?: string;
}

export interface SearchResult {
  content: string;
  annotations: Citation[];
}

export async function webSearch(query: string, gen: GenProfile): Promise<SearchResult | null> {
  const p = config.aiVision;
  if (!p) return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), gen.timeoutMs ?? 45_000);
  try {
    const res = await fetch(`${p.baseUrl.replace(/\/$/, "")}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${p.apiKey}` },
      body: JSON.stringify({
        model: p.model,
        max_tokens: gen.maxTokens,
        temperature: gen.temperature,
        messages: [{ role: "user", content: query }],
        tools: [{ type: "web_search", max_keyword: 3, force_search: true, limit: 3 }],
      }),
      signal: controller.signal,
    });
    if (!res.ok) {
      await logHttpFailure("search", res);
      return null;
    }
    const data = (await res.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
      annotations?: Array<{ url?: string; title?: string; cite_url?: string }>;
    };
    const content = data.choices?.[0]?.message?.content;
    const content2 = content ? String(content).trim() || null : null;
    // MiMo 把 annotations 放在 choices 之外；也兼容放在 message.annotations 里的实现。
    const rawAnnotations = data.annotations ?? [];
    const annotations: Citation[] = rawAnnotations
      .map((a) => ({
        url: String(a.url ?? a.cite_url ?? ""),
        title: String(a.title ?? a.url ?? ""),
        site_name: undefined,
        summary: undefined,
      }))
      .filter((a) => a.url);
    if (!content2 && annotations.length === 0) return null;
    return { content: content2 ?? "", annotations };
  } catch (error) {
    const name = error instanceof Error ? error.name : "";
    console.warn(`[ai] search ${name === "AbortError" ? "超时" : `失败: ${error instanceof Error ? error.message : error}`}`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// 从模型输出里抽出 JSON（容忍 ```json 包裹或前后多余文字）。
export function extractJson<T = unknown>(text: string | null): T | null {
  if (!text) return null;
  const s = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/i, "");
  try {
    return JSON.parse(s) as T;
  } catch {
    /* 继续尝试截取 */
  }
  const a = s.indexOf("{");
  const b = s.lastIndexOf("}");
  if (a !== -1 && b > a) {
    try {
      return JSON.parse(s.slice(a, b + 1)) as T;
    } catch {
      /* 放弃 */
    }
  }
  const arrA = s.indexOf("[");
  const arrB = s.lastIndexOf("]");
  if (arrA !== -1 && arrB > arrA) {
    try {
      return JSON.parse(s.slice(arrA, arrB + 1)) as T;
    } catch {
      /* 放弃 */
    }
  }
  return null;
}

// JSON 解析失败时的兜底（通常是 maxTokens 截断）：正则抠出 replies 数组第一条。
export function extractReplyText(text: string | null): string | null {
  const s = String(text ?? "");
  const m = s.match(/"replies"\s*:\s*\[\s*"((?:\\.|[^"\\])*)/);
  if (!m) return null;
  return m[1]
    .replace(/\\n/g, "\n")
    .replace(/\\"/g, '"')
    .replace(/\\\\/g, "\\");
}
