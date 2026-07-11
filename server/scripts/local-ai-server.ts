import fs from "node:fs";
import path from "node:path";
import dotenv from "dotenv";

const aiEnvPath = path.resolve(".data/production-ai.env");
if (fs.existsSync(aiEnvPath)) {
  const remote = dotenv.parse(fs.readFileSync(aiEnvPath));
  for (const [key, value] of Object.entries(remote)) {
    if (/^(AI|EMBEDDING)_/.test(key) && process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
}

process.env.DATABASE_URL ??= "postgres://couplechat:couplechat@127.0.0.1:55432/couplechat";
process.env.NODE_ENV = "development";
process.env.HOST ??= "127.0.0.1";
process.env.PORT ??= "8080";

async function main(): Promise<void> {
  await import("../src/server");
}

void main().catch((error) => {
  console.error("[local-ai] 启动失败", error);
  process.exitCode = 1;
});
