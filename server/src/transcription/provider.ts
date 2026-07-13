import fs from "node:fs/promises";
import type { TranscriptionProvider } from "./service";

interface TranscriptionConfiguration {
  name: string;
  baseUrl: string;
  apiKey: string;
  model: string;
  language?: string;
  timeoutMs: number;
}

function isDashScopeQwen(config: TranscriptionConfiguration) {
  return config.name === "dashscope-qwen"
    || (config.baseUrl.includes("dashscope.aliyuncs.com") && config.model.startsWith("qwen"));
}

function transcriptionText(payload: unknown): string | undefined {
  if (!payload || typeof payload !== "object") return undefined;
  const choices = (payload as { choices?: unknown }).choices;
  if (!Array.isArray(choices)) return undefined;
  const message = choices[0] && typeof choices[0] === "object"
    ? (choices[0] as { message?: unknown }).message
    : undefined;
  if (!message || typeof message !== "object") return undefined;
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content.trim() || undefined;
  if (!Array.isArray(content)) return undefined;
  const text = content
    .map((item) => item && typeof item === "object" ? (item as { text?: unknown }).text : undefined)
    .filter((item): item is string => typeof item === "string")
    .join("")
    .trim();
  return text || undefined;
}

export function transcriptionConfiguration(): TranscriptionConfiguration | null {
  const baseUrl = process.env.TRANSCRIPTION_BASE_URL?.trim();
  const apiKey = process.env.TRANSCRIPTION_API_KEY?.trim();
  const model = process.env.TRANSCRIPTION_MODEL?.trim();
  if (!baseUrl || !apiKey || !model) return null;
  return {
    name: process.env.TRANSCRIPTION_PROVIDER?.trim() || "openai-compatible",
    baseUrl,
    apiKey,
    model,
    language: process.env.TRANSCRIPTION_LANGUAGE?.trim() || undefined,
    timeoutMs: Math.max(1_000, Number(process.env.TRANSCRIPTION_TIMEOUT_MS ?? 120_000)),
  };
}

export function createConfiguredTranscriptionProvider(): TranscriptionProvider | null {
  const config = transcriptionConfiguration();
  if (!config) return null;
  return {
    name: config.name,
    async transcribe(input) {
      const bytes = await fs.readFile(input.path);
      if (isDashScopeQwen(config)) {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), config.timeoutMs);
        try {
          const response = await fetch(`${config.baseUrl.replace(/\/$/, "")}/chat/completions`, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${config.apiKey}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: config.model,
              messages: [{
                role: "user",
                content: [{
                  type: "input_audio",
                  input_audio: {
                    data: `data:${input.mimeType};base64,${bytes.toString("base64")}`,
                  },
                }],
              }],
              stream: false,
              asr_options: {
                ...(config.language ? { language: config.language } : {}),
                enable_itn: true,
              },
            }),
            signal: controller.signal,
          });
          if (!response.ok) {
            const detail = (await response.text().catch(() => "")).replace(/\s+/g, " ").slice(0, 300);
            throw new Error(`transcription_http_${response.status}${detail ? `:${detail}` : ""}`);
          }
          const text = transcriptionText(await response.json());
          if (!text) throw new Error("empty_transcript");
          return { text, language: config.language };
        } finally {
          clearTimeout(timeout);
        }
      }
      const form = new FormData();
      form.append("model", config.model);
      if (config.language) form.append("language", config.language);
      form.append("file", new Blob([bytes], { type: input.mimeType }), `${input.messageId}.m4a`);
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), config.timeoutMs);
      try {
        const response = await fetch(`${config.baseUrl.replace(/\/$/, "")}/audio/transcriptions`, {
          method: "POST",
          headers: { Authorization: `Bearer ${config.apiKey}` },
          body: form,
          signal: controller.signal,
        });
        if (!response.ok) {
          const detail = (await response.text().catch(() => "")).replace(/\s+/g, " ").slice(0, 300);
          throw new Error(`transcription_http_${response.status}${detail ? `:${detail}` : ""}`);
        }
        const payload = await response.json() as { text?: unknown; language?: unknown };
        if (typeof payload.text !== "string" || !payload.text.trim()) throw new Error("empty_transcript");
        return {
          text: payload.text,
          language: typeof payload.language === "string" ? payload.language : config.language,
        };
      } finally {
        clearTimeout(timeout);
      }
    },
  };
}
