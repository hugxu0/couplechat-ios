import { accounts } from "../accounts";
import { compactLines, messagesBetween } from "../conversation/log";
import { aiEnabled, chat } from "../provider";
import { readRuntimeState, writeRuntimeState } from "../runtimeState";
import { addDays, cycleBounds, cycleDate } from "../time";
import { sanitizeDiaryText } from "./diaryText";

const DIARY_GEN = { maxTokens: 1000, temperature: 0.75, timeoutMs: 60_000 };

export async function generateDiary(date: string, force = false): Promise<void> {
  if (!force && await readRuntimeState(`diary:${date}`)) return;
  const { start, end } = cycleBounds(date);
  const messages = (await messagesBetween("couple", start, end)).filter((message) => message.kind !== "system");
  if (!messages.length || !aiEnabled()) return;
  const output = await chat({
    profile: "task",
    system: [
      "你是大橘，把两位主人昨天的聊天写成一篇他们都能看到的短日记。",
      `两位主人是 ${accounts().map((account) => account.name).join(" 和 ")}。`,
      "不要写成聊天流水账。只选择一两个真实而有意味的片段，从大橘的视角写它观察到的细节、自己的感受、思考或小见解。",
      "不能编造聊天中没有的事实，也不要评判主人、复述伤人的原话。用大橘第一人称，150~300 字，语气自然，有猫的个性。",
      "正文不要标题，不要在开头或正文中写日期、年份、月份、星期；日期会由界面单独展示。",
    ].join("\n"),
    user: compactLines(messages, 180).slice(-16000),
    gen: DIARY_GEN,
  });
  const text = output ? sanitizeDiaryText(output) : "";
  if (text) await writeRuntimeState(`diary:${date}`, text.slice(0, 1200));
}

export async function regenerateDiary(date: string): Promise<void> {
  await generateDiary(date, true);
}

let diaryHistoryBackfilling = false;

export function isDiaryHistoryBackfilling(): boolean {
  return diaryHistoryBackfilling;
}

export async function backfillDiaryHistory(days = 30): Promise<void> {
  if (diaryHistoryBackfilling || !aiEnabled()) return;
  diaryHistoryBackfilling = true;
  try {
    const today = cycleDate();
    for (let offset = 1; offset <= days; offset += 1) {
      await generateDiary(addDays(today, -offset)).catch((error) => {
        console.warn("[ai] 历史日记生成失败:", error instanceof Error ? error.message : error);
      });
    }
  } finally {
    diaryHistoryBackfilling = false;
  }
}

export async function dailyContent() {
  const today = cycleDate();
  const diaries: Array<{ date: string; text: string }> = [];
  for (let offset = 1; offset <= 30; offset += 1) {
    const date = addDays(today, -offset);
    const text = await readRuntimeState(`diary:${date}`);
    if (text) diaries.push({ date, text });
  }
  return { diaries, backfilling: diaryHistoryBackfilling, requestedDays: 30 };
}
