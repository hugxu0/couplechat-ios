#!/usr/bin/env node

// 将 DATABASE_URL 转成权限为 0600 的 libpq service/.pgpass 文件。
// URL 只从环境变量读取，避免密码出现在 ps 的命令行参数中。

import { chmod, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

const rawURL = process.env.COUPLECHAT_DATABASE_URL ?? "";
const outputDirectory = process.env.PG_SERVICE_OUTPUT_DIR ?? "";
const serviceName = process.env.PG_SERVICE_NAME ?? "couplechat";
const databaseOverride = process.env.PG_DATABASE_OVERRIDE ?? "";

function fail(message) {
  process.stderr.write(`[pg-service] ${message}\n`);
  process.exit(2);
}

if (!rawURL) fail("COUPLECHAT_DATABASE_URL 不能为空");
if (!path.isAbsolute(outputDirectory)) fail("PG_SERVICE_OUTPUT_DIR 必须是绝对路径");
if (!/^[A-Za-z][A-Za-z0-9_-]{0,62}$/.test(serviceName)) fail("PG_SERVICE_NAME 不合法");
if (databaseOverride && !/^[A-Za-z0-9_]{1,63}$/.test(databaseOverride)) {
  fail("PG_DATABASE_OVERRIDE 不合法");
}

let databaseURL;
try {
  databaseURL = new URL(rawURL);
} catch {
  fail("仅支持 postgres:// 或 postgresql:// 格式的 DATABASE_URL");
}
if (!['postgres:', 'postgresql:'].includes(databaseURL.protocol)) {
  fail("仅支持 postgres:// 或 postgresql:// 格式的 DATABASE_URL");
}
if (databaseURL.hash) fail("DATABASE_URL 不能包含 URL fragment");

const decode = (value, field) => {
  try {
    const decoded = decodeURIComponent(value);
    if (/[\r\n\0]/u.test(decoded)) fail(`${field} 含有非法控制字符`);
    return decoded;
  } catch {
    fail(`${field} 的 URL 编码不合法`);
  }
};

const sanitize = (value, field) => {
  if (/[\r\n\0]/u.test(value)) fail(`${field} 含有非法控制字符`);
  return value;
};

const username = decode(databaseURL.username, "username");
const password = decode(databaseURL.password, "password");
let hostname = databaseURL.hostname;
if (hostname.startsWith("[") && hostname.endsWith("]")) hostname = hostname.slice(1, -1);
hostname = decode(hostname, "hostname");
const port = databaseURL.port || "5432";
const pathDatabase = databaseURL.pathname.replace(/^\//u, "");
const database = databaseOverride || decode(pathDatabase, "database");

if (!hostname) fail("DATABASE_URL 必须显式包含主机名");
if (!username) fail("DATABASE_URL 必须显式包含用户名");
if (!database) fail("DATABASE_URL 必须显式包含数据库名");
if (!/^\d{1,5}$/u.test(port) || Number(port) < 1 || Number(port) > 65535) fail("端口不合法");

// 只转发 libpq 明确认识且不会改变凭据文件位置的连接参数。
const allowedParameters = new Set([
  "application_name",
  "channel_binding",
  "client_encoding",
  "connect_timeout",
  "gssencmode",
  "hostaddr",
  "keepalives",
  "keepalives_count",
  "keepalives_idle",
  "keepalives_interval",
  "load_balance_hosts",
  "options",
  "requirepeer",
  "sslcert",
  "sslcrl",
  "sslcrldir",
  "sslkey",
  "sslmode",
  "sslnegotiation",
  "sslrootcert",
  "ssl_max_protocol_version",
  "ssl_min_protocol_version",
  "target_session_attrs",
  "tcp_user_timeout",
]);

const serviceLines = [
  `[${serviceName}]`,
  `host=${hostname}`,
  `port=${port}`,
  `dbname=${database}`,
  `user=${username}`,
];

const seenParameters = new Set();
for (const [key, rawValue] of databaseURL.searchParams) {
  if (!allowedParameters.has(key)) fail(`不支持 DATABASE_URL 参数: ${key}`);
  if (seenParameters.has(key)) fail(`DATABASE_URL 参数重复: ${key}`);
  seenParameters.add(key);
  // URLSearchParams 已完成百分号解码，不能再次 decodeURIComponent。
  const value = sanitize(rawValue, `query.${key}`);
  serviceLines.push(`${key}=${value}`);
}

const escapePgpass = (value) => value.replaceAll("\\", "\\\\").replaceAll(":", "\\:");
const pgpassLine = [hostname, port, database, username, password].map(escapePgpass).join(":");

await mkdir(outputDirectory, { recursive: true, mode: 0o700 });
await chmod(outputDirectory, 0o700);
await writeFile(path.join(outputDirectory, "pg_service.conf"), `${serviceLines.join("\n")}\n`, {
  encoding: "utf8",
  mode: 0o600,
});
await writeFile(path.join(outputDirectory, ".pgpass"), `${pgpassLine}\n`, {
  encoding: "utf8",
  mode: 0o600,
});
await chmod(path.join(outputDirectory, "pg_service.conf"), 0o600);
await chmod(path.join(outputDirectory, ".pgpass"), 0o600);
