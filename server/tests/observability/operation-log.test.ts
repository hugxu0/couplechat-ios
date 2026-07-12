import assert from "node:assert/strict";
import test from "node:test";
import { errorCodeFor, errorCodes } from "../../src/errors/errorCodes";
import { startOperation } from "../../src/observability/operationLog";

test("operation logs retain correlation fields and discard sensitive content", () => {
  const output: string[] = [];
  const original = console.info;
  console.info = (value?: unknown) => { output.push(String(value)); };
  try {
    startOperation("message.send", {
      requestId: "req_1",
      clientId: "client_1",
      channel: "couple",
      text: "private message",
      token: "secret token",
    }).success();
  } finally {
    console.info = original;
  }
  const logged = JSON.parse(output[0]) as Record<string, unknown>;
  assert.equal(logged.requestId, "req_1");
  assert.equal(logged.clientId, "client_1");
  assert.equal(logged.channel, "couple");
  assert.equal("text" in logged, false);
  assert.equal("token" in logged, false);
});

test("unknown failures collapse to a stable internal error code", () => {
  assert.equal(errorCodeFor(new Error("database details")), errorCodes.internal);
  assert.equal(errorCodeFor(new Error("upload_not_found")), errorCodes.uploadNotFound);
});
