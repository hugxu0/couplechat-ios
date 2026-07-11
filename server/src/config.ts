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

function booleanEnv(name: string, fallback: boolean): boolean {
  const value = process.env[name];
  if (value === undefined) return fallback;
  return !["0", "false", "no", "off"].includes(value.trim().toLowerCase());
}

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

// chat 用于用户回复，task 用于记忆提取和后台任务。
const aiShared = providerFromEnv("AI");
const aiTask = providerFromEnv("AI_TASK", aiShared);
// 向量池：优先用新的多 key 池格式（EMBEDDING_<NAME>_PROVIDER/_BASE_URL/_API_KEYS）；
// 没配的话退回旧的单 key 格式（EMBEDDING_BASE_URL/_API_KEY/_MODEL），保持兼容。
const embeddingPools = [embeddingPoolFromEnv("VOYAGE"), embeddingPoolFromEnv("MONGODB")].filter(
  (p): p is EmbeddingPool => Boolean(p),
);
const fallbackEmbedding = providerFromEnv("EMBEDDING");
if (embeddingPools.length === 0 && fallbackEmbedding) {
  embeddingPools.push({ name: "fallback", baseUrl: fallbackEmbedding.baseUrl, apiKeys: [fallbackEmbedding.apiKey] });
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
  dataDir: path.resolve(process.env.DATA_DIR ?? path.join(process.cwd(), ".data")),
  uploadDir: path.resolve(process.env.UPLOAD_DIR ?? path.join(process.cwd(), "uploads")),
  // PostgreSQL 连接串（部署时用 DATABASE_URL 覆盖）
  databaseUrl: process.env.DATABASE_URL ?? "postgres://couplechat:couplechat@localhost:5432/couplechat",
  ai: {
    chat: providerFromEnv("AI_CHAT", aiShared),
    task: aiTask,
    // couple 频道召唤词；ai 私聊频道每条都答，不需要召唤。
    triggerAliases: (process.env.AI_TRIGGER_ALIASES ?? "@大橘")
      .split(/[,，;；]/)
      .map((s) => s.trim())
      .filter(Boolean),
  },
  aiMcpUrl: process.env.AI_MCP_URL ?? `http://127.0.0.1:${Number(process.env.PORT ?? 8080)}/api/ai-mcp`,
  // 图片识图（多模态）：只有消息带图片时才调用，未配置则直接跳过图片。
  aiVision: providerFromEnv("AI_VISION"),
  embeddingPools,
  embeddingModel: process.env.EMBEDDING_MODEL ?? fallbackEmbedding?.model ?? "voyage-4",
  embeddingDim: Number(process.env.EMBEDDING_DIM ?? 1024),
  cloudDatabaseDebug: booleanEnv("CLOUD_DB_DEBUG", false),
  scheduledJobsEnabled: booleanEnv("SCHEDULED_JOBS_ENABLED", true),
  uploadsWritable: booleanEnv("UPLOADS_WRITABLE", true),
  pushEnabled: booleanEnv("PUSH_ENABLED", true),
};
