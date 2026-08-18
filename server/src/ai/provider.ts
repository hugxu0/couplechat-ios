// LLM 客户端：仅 OpenAI 兼容的 Responses / Chat Completions。
// 失败/未配置一律返回 null，由调用方给出明确失败提示。

import { config, type AiProvider } from "../config";
import { responsesReasoningSettings, type GenProfile } from "./settings";

// 图片理解走 agent/runtime 的 vision 多模态模型（DeepSeek 等纯文本模型不识图）。

export type ChatProfile = "chat" | "task" | "vision";

export function aiEnabled(): boolean {
  return Boolean(config.ai.chat || config.ai.task);
}

function providerFor(profile: ChatProfile): AiProvider | undefined {
  return config.ai[profile] ?? config.ai.chat ?? config.ai.task;
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
  /** 仅用于脱敏运维日志区分任务阶段，不包含用户正文。 */
  scope?: string;
  system: string;
  user: string;
  gen: GenProfile;
  signal?: AbortSignal;
}

function logScope(args: ChatArgs): string {
  return args.scope?.replace(/[^a-z0-9_.-]/gi, "_").slice(0, 60) || args.profile;
}

function safeHeaderValue(value: string | null): string {
  return value?.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 160) ?? "";
}

export function formatProviderHttpFailure(scope: string, res: Response): string {
  const requestId = safeHeaderValue(
    res.headers.get("x-request-id")
      ?? res.headers.get("request-id")
      ?? res.headers.get("openai-request-id"),
  );
  const retryAfter = safeHeaderValue(res.headers.get("retry-after"));
  return `[ai] ${scope} HTTP ${res.status}`
    + (requestId ? ` request-id=${requestId}` : "")
    + (retryAfter ? ` retry-after=${retryAfter}` : "");
}

async function logHttpFailure(scope: string, res: Response): Promise<void> {
  const line = formatProviderHttpFailure(scope, res);
  await res.body?.cancel().catch(() => undefined);
  console.warn(line);
}

async function chatOpenAi(p: AiProvider, args: ChatArgs, signal: AbortSignal): Promise<string | null> {
  const effort = args.gen.reasoningEffort ?? p.reasoningEffort;
  const res = await fetch(`${p.baseUrl.replace(/\/$/, "")}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${p.apiKey}` },
    body: JSON.stringify({
      model: p.model,
      max_tokens: args.gen.maxTokens,
      temperature: args.gen.temperature,
      ...(effort ? { reasoning_effort: effort } : {}),
      messages: [
        { role: "system", content: args.system },
        { role: "user", content: args.user },
      ],
    }),
    signal,
  });
  if (!res.ok) {
    await logHttpFailure(logScope(args), res);
    return null;
  }
  const data = (await res.json()) as {
    choices?: Array<{ message?: { content?: string }; finish_reason?: string }>;
  };
  const content = data.choices?.[0]?.message?.content;
  const text = content ? String(content).trim() || null : null;
  if (!text) console.warn(`[ai] ${logScope(args)} 空响应 finish_reason=${data.choices?.[0]?.finish_reason ?? "unknown"}`);
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
    await logHttpFailure(`${logScope(args)} responses`, res);
    return null;
  }
  const text = responsesText(await res.json());
  if (!text) console.warn(`[ai] ${logScope(args)} responses 空响应`);
  return text;
}

export async function chat(args: ChatArgs): Promise<string | null> {
  const provider = providerFor(args.profile);
  if (!provider) return null;
  const controller = new AbortController();
  const cancelFromCaller = () => controller.abort(args.signal?.reason);
  if (args.signal?.aborted) cancelFromCaller();
  else args.signal?.addEventListener("abort", cancelFromCaller, { once: true });
  const timer = setTimeout(() => controller.abort(), args.gen.timeoutMs ?? 30_000);
  try {
    if (provider.apiMode === "responses") {
      return await chatOpenAiResponses(provider, args, controller.signal);
    }
    return await chatOpenAi(provider, args, controller.signal);
  } catch (error) {
    if (args.signal?.aborted) {
      throw args.signal.reason instanceof Error
        ? args.signal.reason
        : new Error("ai_request_cancelled");
    }
    const name = error instanceof Error ? error.name : "";
    console.warn(`[ai] ${logScope(args)} ${name === "AbortError" ? "超时" : `失败: ${error instanceof Error ? error.message : error}`}`);
    return null;
  } finally {
    clearTimeout(timer);
    args.signal?.removeEventListener("abort", cancelFromCaller);
  }
}

export interface Citation {
  url: string;
  title: string;
  site_name?: string;
  summary?: string;
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
