import fs from "node:fs";
import path from "node:path";
import dotenv from "dotenv";

if (!process.env.DATABASE_URL) {
  throw new Error("cloud-ai-server must be started through npm run dev:cloud-db");
}

const aiEnvPath = path.resolve(".data/production-ai.env");
if (fs.existsSync(aiEnvPath)) {
  const productionEnv = dotenv.parse(fs.readFileSync(aiEnvPath));
  for (const [key, value] of Object.entries(productionEnv)) {
    if (process.env[key] === undefined) process.env[key] = value;
  }
}

process.env.NODE_ENV = "development";
process.env.HOST = "127.0.0.1";
process.env.PORT = "8080";
process.env.PUBLIC_BASE_URL = "http://127.0.0.1:8080";
// 防御性重复设置：这个脚本只允许校验现有 schema，绝不能把候选 migration 带进生产。
process.env.RUN_MIGRATIONS = "false";

async function main(): Promise<void> {
  await import("../src/server");
}

void main().catch((error) => {
  console.error("[cloud-ai] startup failed", error);
  process.exitCode = 1;
});
