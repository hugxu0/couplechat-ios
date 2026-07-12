import assert from "node:assert/strict";
import test from "node:test";
import { installSafeTestEnvironment } from "../support/testEnv";

installSafeTestEnvironment();

test("memory visibility keeps private AI scopes isolated", async () => {
  const { visibleMemoryScopes } = await import("../../src/ai/memory/store");
  assert.deepEqual(visibleMemoryScopes("couple"), ["couple"]);
  assert.deepEqual(visibleMemoryScopes("ai:xu"), ["couple", "ai:xu"]);
  assert.deepEqual(visibleMemoryScopes("ai:si"), ["couple", "ai:si"]);
});

test("memory extraction requires a full batch unless forced", async () => {
  const { MEMORY_SOURCE_BATCH_SIZE, minimumEvidenceForLayer, shouldExtractMemoryBatch } =
    await import("../../src/ai/memory/extractor");
  assert.equal(shouldExtractMemoryBatch(MEMORY_SOURCE_BATCH_SIZE - 1), false);
  assert.equal(shouldExtractMemoryBatch(1, true), true);
  assert.equal(shouldExtractMemoryBatch(0, true), false);
  assert.equal(minimumEvidenceForLayer("insight"), 3);
  assert.equal(minimumEvidenceForLayer("fact"), 1);
});
