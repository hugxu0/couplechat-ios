// 向量客户端：OpenAI 兼容 POST /embeddings（Voyage / OpenAI / 硅基流动等通吃）。
// 未配置时所有函数优雅降级——召回退化为「高重要度事实兜底」，聊天照常。
// 向量在写入时归一化，余弦相似度 = 点积；体量只有两个人，JS 里全量扫足够快。

import { config } from "../config";

export function embeddingEnabled(): boolean {
  return Boolean(config.embedding);
}

export async function embed(texts: string[]): Promise<Float32Array[] | null> {
  const p = config.embedding;
  if (!p || texts.length === 0) return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 60_000);
  try {
    const res = await fetch(`${p.baseUrl.replace(/\/$/, "")}/embeddings`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${p.apiKey}` },
      body: JSON.stringify({ model: p.model, input: texts }),
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
  const copy = new Uint8Array(blob); // sql.js 返回的可能是共享 buffer 的视图，复制一份
  return new Float32Array(copy.buffer);
}
