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
