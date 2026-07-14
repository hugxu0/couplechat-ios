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

test("memory extraction follows hybrid conversation segmentation", async () => {
  const {
    MEMORY_BUSY_IDLE_MS,
    MEMORY_MAX_BATCH_AGE_MS,
    MEMORY_QUIET_IDLE_MS,
    MEMORY_SOURCE_BATCH_SIZE,
    memoryExtractionDelay,
    shouldExtractMemoryBatch,
  } =
    await import("../../src/ai/memory/extractor");
  assert.equal(shouldExtractMemoryBatch(MEMORY_SOURCE_BATCH_SIZE - 1), false);
  assert.equal(shouldExtractMemoryBatch(1, true), true);
  assert.equal(shouldExtractMemoryBatch(0, true), false);
  const now = 10 * 60 * 60 * 1000;
  assert.equal(memoryExtractionDelay(8, now, now, now), MEMORY_QUIET_IDLE_MS);
  assert.equal(memoryExtractionDelay(20, now, now, now), MEMORY_BUSY_IDLE_MS);
  assert.equal(memoryExtractionDelay(8, now - MEMORY_MAX_BATCH_AGE_MS, now, now), 0);
  assert.equal(memoryExtractionDelay(MEMORY_SOURCE_BATCH_SIZE, now, now, now), 0);
});
