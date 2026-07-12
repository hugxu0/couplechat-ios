import assert from "node:assert/strict";
import test from "node:test";
import { clientChannelSchema, readReceiptSchema } from "../../src/contracts/realtime";
import { toClientChannel, toStoredChannel } from "../../src/types";

test("sync contracts normalize iOS timestamps and isolate AI channels", () => {
  const receipt = readReceiptSchema.parse({ channel: "couple", ts: 1783653931714.444 });
  assert.equal(receipt.ts, 1783653931714);
  assert.equal(clientChannelSchema.safeParse("unknown").success, false);
  assert.equal(toStoredChannel("ai", "xu"), "ai:xu");
  assert.equal(toClientChannel("ai:xu"), "ai");
  assert.equal(toStoredChannel("couple", "xu"), "couple");
});
