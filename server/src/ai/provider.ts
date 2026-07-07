// LLM 客户端：OpenAI 兼容 /chat/completions + Anthropic 原生 /messages 双协议。
// 失败/未配置一律返回 null，调用方自行兜底——用户永远不该看到堆栈。

import { config, type AiProvider } from "../config";
import type { GenProfile } from "./params";

export type ChatProfile = "chat" | "task";

export function aiEnabled(): boolean {
  return Boolean(config.ai.chat || config.ai.task);
}

export function visionEnabled(): boolean {
  return Boolean(config.aiVision);
}

function providerFor(profile: ChatProfile): AiProvider | undefined {
  return config.ai[profile] ?? config.ai.chat ?? config.ai.task;
}

function isClaudeModel(model: string) {
  return /^claude-/i.test(model);
}

interface ChatArgs {
  profile: ChatProfile;
  system: string;
  user: string;
  gen: GenProfile;
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
    console.warn(`[ai] ${args.profile} anthropic HTTP ${res.status}`);
    return null;
  }
  const data = (await res.json()) as { content?: Array<{ type: string; text?: string }> };
  const text = (data.content ?? [])
    .filter((b) => b.type === "text" && b.text)
    .map((b) => b.text)
    .join("");
  return text.trim() || null;
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
    console.warn(`[ai] ${args.profile} HTTP ${res.status}`);
    return null;
  }
  const data = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
  const content = data.choices?.[0]?.message?.content;
  return content ? String(content).trim() : null;
}

export async function chat(args: ChatArgs): Promise<string | null> {
  const provider = providerFor(args.profile);
  if (!provider) return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), args.gen.timeoutMs ?? 30_000);
  try {
    return isClaudeModel(provider.model)
      ? await chatAnthropic(provider, args, controller.signal)
      : await chatOpenAi(provider, args, controller.signal);
  } catch (error) {
    const name = error instanceof Error ? error.name : "";
    console.warn(`[ai] ${args.profile} ${name === "AbortError" ? "超时" : `失败: ${error instanceof Error ? error.message : error}`}`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// 识图：OpenAI 兼容的多模态 /chat/completions，image_url 直接传公网可访问的图片地址。
// 只在消息带图片时调用，未配置 AI_VISION_* 或调用失败都直接返回 null，调用方按纯文字兜底。
export async function describeImage(imageUrl: string, gen: GenProfile, prompt = "用一两句话简短描述这张图片的内容，中文回答。"): Promise<string | null> {
  const p = config.aiVision;
  if (!p) return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), gen.timeoutMs ?? 30_000);
  try {
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
              { type: "image_url", image_url: { url: imageUrl } },
            ],
          },
        ],
      }),
      signal: controller.signal,
    });
    if (!res.ok) {
      console.warn(`[ai] vision HTTP ${res.status}`);
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
