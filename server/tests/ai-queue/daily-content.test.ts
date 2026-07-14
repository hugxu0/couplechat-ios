import assert from "node:assert/strict";
import test from "node:test";
import { sanitizeDiaryText } from "../../src/ai/background/diaryText";

test("diary output removes generated titles and leading dates", () => {
  assert.equal(
    sanitizeDiaryText("# 大橘日记\n2024年7月13日 星期六：我今天发现两位主人说话都轻了一点。"),
    "我今天发现两位主人说话都轻了一点。",
  );
  assert.equal(
    sanitizeDiaryText("7月13日，我趴在窗边听见他们认真商量周末。"),
    "我趴在窗边听见他们认真商量周末。",
  );
});
