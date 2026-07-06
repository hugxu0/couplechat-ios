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
};
