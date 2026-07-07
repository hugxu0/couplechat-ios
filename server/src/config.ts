import path from "node:path";
import dotenv from "dotenv";

dotenv.config();

function required(name: string): string {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

const nodeEnv = process.env.NODE_ENV ?? "development";
const tokenSecret = required("TOKEN_SECRET");

if (nodeEnv === "production" && tokenSecret === "change-me-before-production") {
  throw new Error("TOKEN_SECRET must be changed in production");
}

export interface AiProvider {
  baseUrl: string;
  apiKey: string;
  model: string;
}

function providerFromEnv(prefix: string, fallback?: AiProvider): AiProvider | undefined {
  const baseUrl = process.env[`${prefix}_BASE_URL`] ?? fallback?.baseUrl ?? "";
  const apiKey = process.env[`${prefix}_API_KEY`] ?? fallback?.apiKey ?? "";
  const model = process.env[`${prefix}_MODEL`] ?? fallback?.model ?? "";
  if (!baseUrl || !apiKey || !model) return undefined;
  return { baseUrl, apiKey, model };
}

// 向量账号池：一个 provider = 一个 baseUrl + 一串 key（逗号分隔）。
// 调用时按 provider 顺序、每个 provider 内按 key 顺序试，失败立刻换下一个。
export interface EmbeddingPool {
  name: string;
  baseUrl: string;
  apiKeys: string[];
}

function embeddingPoolFromEnv(prefix: string): EmbeddingPool | undefined {
  const name = process.env[`EMBEDDING_${prefix}_PROVIDER`] ?? "";
  const baseUrl = process.env[`EMBEDDING_${prefix}_BASE_URL`] ?? "";
  const apiKeys = (process.env[`EMBEDDING_${prefix}_API_KEYS`] ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (!name || !baseUrl || apiKeys.length === 0) return undefined;
  return { name, baseUrl, apiKeys };
}

// 模型只分两档（对比旧后端 15 个 profile 大幅精简）：
//   chat = 直面用户的对话回复（要快、要有人味）
//   task = 后台任务（记忆提取/日记/卡片/收口，可以慢、要稳定输出 JSON）
// 只配 AI_* 时两档共用同一个模型；AI_CHAT_* / AI_TASK_* 可分别覆盖。
const aiShared = providerFromEnv("AI");

// 向量池：优先用新的多 key 池格式（EMBEDDING_<NAME>_PROVIDER/_BASE_URL/_API_KEYS）；
// 没配的话退回旧的单 key 格式（EMBEDDING_BASE_URL/_API_KEY/_MODEL），保持兼容。
const embeddingPools = [embeddingPoolFromEnv("VOYAGE"), embeddingPoolFromEnv("MONGODB")].filter(
  (p): p is EmbeddingPool => Boolean(p),
);
const legacyEmbedding = providerFromEnv("EMBEDDING");
if (embeddingPools.length === 0 && legacyEmbedding) {
  embeddingPools.push({ name: "legacy", baseUrl: legacyEmbedding.baseUrl, apiKeys: [legacyEmbedding.apiKey] });
}

export const config = {
  nodeEnv,
  isProduction: nodeEnv === "production",
  host: process.env.HOST ?? "0.0.0.0",
  port: Number(process.env.PORT ?? 8080),
  publicBaseURL: process.env.PUBLIC_BASE_URL ?? "http://localhost:8080",
  tokenSecret,
  accountsSeed: process.env.COUPLECHAT_ACCOUNTS ?? "",
  appDeepLinkScheme: process.env.APP_DEEP_LINK_SCHEME ?? "couplechat://",
  dataDir: path.resolve(process.cwd(), ".data"),
  uploadDir: path.resolve(process.cwd(), "uploads"),
  ai: {
    chat: providerFromEnv("AI_CHAT", aiShared),
    task: providerFromEnv("AI_TASK", aiShared),
    // couple 频道召唤词；ai 私聊频道每条都答，不需要召唤。
    triggerAliases: (process.env.AI_TRIGGER_ALIASES ?? "@大橘")
      .split(/[,，;；]/)
      .map((s) => s.trim())
      .filter(Boolean),
  },
  // 图片识图（多模态）：只有消息带图片时才调用，未配置则直接跳过图片。
  aiVision: providerFromEnv("AI_VISION"),
  embeddingPools,
  embeddingModel: process.env.EMBEDDING_MODEL ?? legacyEmbedding?.model ?? "voyage-4",
  embeddingDim: Number(process.env.EMBEDDING_DIM ?? 1024),
};
