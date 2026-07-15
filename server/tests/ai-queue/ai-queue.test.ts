import assert from "node:assert/strict";
import test from "node:test";
import { installSafeTestEnvironment } from "../support/testEnv";

installSafeTestEnvironment();

const trigger = {
  storedChannel: "ai:test" as const,
  question: "q1",
  requesterName: "测试用户",
  requesterUsername: "test",
};

test("AI timeout emits one fallback and clears typing", async () => {
  const { runReplyTaskWithTimeout } = await import("../../src/ai/agent/replyQueue");
  const replies: string[] = [];
  const typing: boolean[] = [];
  await runReplyTaskWithTimeout(
    trigger,
    {
      emit: async (_channel, text) => { replies.push(text); },
      typing: (_channel, value) => { typing.push(value); },
    },
    async () => new Promise<void>(() => undefined),
    5,
  );
  assert.equal(replies.length, 1);
  assert.equal(typing.at(-1), false);
});

test("Responses reasoning explicitly requests a compatible summary shape", async () => {
  const { responsesReasoningSettings } = await import("../../src/ai/settings");
  assert.deepEqual(responsesReasoningSettings("high"), { effort: "high", summary: "auto" });
  assert.deepEqual(responsesReasoningSettings(undefined), undefined);
});

test("AI queue coalesces overload to the newest request", async () => {
  const { ReplyQueue } = await import("../../src/ai/agent/replyQueue");
  const started: string[] = [];
  let release: (() => void) | undefined;
  const first = new Promise<void>((resolve) => { release = resolve; });
  const queue = new ReplyQueue(async (item) => {
    started.push(item.question);
    if (item.question === "q1") await first;
  }, 2);
  const sink = { emit: async () => undefined, typing: () => undefined };
  assert.equal(queue.enqueue(trigger, sink), "queued");
  assert.equal(queue.enqueue({ ...trigger, question: "q2" }, sink), "queued");
  assert.equal(queue.enqueue({ ...trigger, question: "q3" }, sink), "coalesced");
  assert.equal(queue.enqueue({ ...trigger, question: "q4" }, sink), "coalesced");
  await new Promise((resolve) => setTimeout(resolve, 5));
  release?.();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.deepEqual(started, ["q1", "q2", "q4"]);
});

test("personal item drafts resolve scope from the conversation unless explicitly overridden", async () => {
  const { defaultPersonalItemScope, resolveDraftPersonalItemScope } = await import("../../src/ai/mcp/personalItemTools");
  assert.equal(defaultPersonalItemScope("couple"), "shared");
  assert.equal(defaultPersonalItemScope("ai:xu"), "personal");
  assert.equal(resolveDraftPersonalItemScope("couple"), "shared");
  assert.equal(resolveDraftPersonalItemScope("ai:xu"), "personal");
  assert.equal(resolveDraftPersonalItemScope("couple", "personal"), "personal");
  assert.equal(resolveDraftPersonalItemScope("ai:xu", "shared"), "shared");
});
