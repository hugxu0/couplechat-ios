import { get, run } from "../db";

export async function readRuntimeState(key: string): Promise<string> {
  const row = await get<{ value: string }>("SELECT value FROM ai_runtime_state WHERE key = ?", [key]);
  return row?.value ?? "";
}

export async function writeRuntimeState(key: string, value: string): Promise<void> {
  await run(
    `INSERT INTO ai_runtime_state (key, value, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at`,
    [key, value, Date.now()],
  );
}
