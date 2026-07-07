// 向量客户端：OpenAI 兼容 POST /embeddings（Voyage / OpenAI / 硅基流动 / MongoDB AI Gateway 等通吃）。
// 未配置时所有函数优雅降级——召回退化为「高重要度事实兜底」，聊天照常。
// 支持多账号池：按 provider 顺序、每个 provider 内按 key 顺序试，某个 key 失败立刻换下一个，
// 全部试完还失败才真正放弃（保留旧的优雅降级行为）。
// 向量在写入时归一化，余弦相似度 = 点积；体量只有两个人，JS 里全量扫足够快。

import { config } from "../config";

export function embeddingEnabled(): boolean {
  return config.embeddingPools.length > 0;
}

async function embedWithKey(baseUrl: string, apiKey: string, texts: string[]): Promise<Float32Array[] | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 60_000);
  try {
    const res = await fetch(`${baseUrl.replace(/\/$/, "")}/embeddings`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ model: config.embeddingModel, input: texts }),
      signal: controller.signal,
    });
    if (!res.ok) {
      console.warn(`[embedding] HTTP ${res.status}`);
      return null;
    }
    const data = (await res.json()) as { data?: Array<{ embedding?: number[] }> };
    const rows = data.data ?? [];
    if (rows.length !== texts.length) return null;
    return rows.map((row) => normalize(Float32Array.from(row.embedding ?? [])));
  } catch (error) {
    console.warn(`[embedding] 失败: ${error instanceof Error ? error.message : error}`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export async function embed(texts: string[]): Promise<Float32Array[] | null> {
  if (texts.length === 0 || config.embeddingPools.length === 0) return null;
  for (const pool of config.embeddingPools) {
    for (const apiKey of pool.apiKeys) {
      const result = await embedWithKey(pool.baseUrl, apiKey, texts);
      if (result) return result;
      console.warn(`[embedding] ${pool.name} 的一个 key 失败，换下一个`);
    }
  }
  console.warn("[embedding] 所有账号池 key 都失败了，本次跳过");
  return null;
}

export async function embedOne(text: string): Promise<Float32Array | null> {
  const result = await embed([text]);
  return result?.[0] ?? null;
}

function normalize(v: Float32Array): Float32Array {
  let sum = 0;
  for (let i = 0; i < v.length; i += 1) sum += v[i] * v[i];
  const norm = Math.sqrt(sum);
  if (norm > 0) {
    for (let i = 0; i < v.length; i += 1) v[i] /= norm;
  }
  return v;
}

// 已归一化向量的余弦相似度 = 点积。
export function similarity(a: Float32Array, b: Float32Array): number {
  const n = Math.min(a.length, b.length);
  let dot = 0;
  for (let i = 0; i < n; i += 1) dot += a[i] * b[i];
  return dot;
}

export function packVector(v: Float32Array): Uint8Array {
  return new Uint8Array(v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength));
}

export function unpackVector(blob: Uint8Array | null): Float32Array | null {
  if (!blob || blob.byteLength === 0 || blob.byteLength % 4 !== 0) return null;
  // Node.js Buffer has a shared ArrayBuffer under the hood.
  // Slice the ArrayBuffer to ensure we get a clean, independent and aligned memory block.
  const buffer = blob.buffer.slice(blob.byteOffset, blob.byteOffset + blob.byteLength);
  return new Float32Array(buffer);
}
