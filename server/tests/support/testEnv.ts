export function installSafeTestEnvironment(): void {
  if (process.env.NODE_ENV === "production") {
    throw new Error("Refusing to run tests with NODE_ENV=production");
  }
  process.env.NODE_ENV = "test";
  process.env.TOKEN_SECRET = "unit-test-secret-never-use-in-production";
  process.env.PUBLIC_BASE_URL = "http://127.0.0.1:8080";
  process.env.SCHEDULED_JOBS_ENABLED = "false";
  process.env.PUSH_ENABLED = "false";
  process.env.UPLOADS_WRITABLE = "true";
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("AI_") || key.startsWith("EMBEDDING_")) delete process.env[key];
  }
}
