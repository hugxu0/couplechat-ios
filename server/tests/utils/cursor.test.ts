import assert from "node:assert/strict";
import test from "node:test";
import { decodeCursor, encodeCursor, isNumberStringCursor } from "../../src/utils/cursor";

test("cursor codec round trips a validated tuple", () => {
  const encoded = encodeCursor([123, "item"]);
  assert.deepEqual(decodeCursor(encoded, isNumberStringCursor), [123, "item"]);
});

test("cursor codec rejects malformed and invalid values", () => {
  assert.equal(decodeCursor("not-base64-json", isNumberStringCursor), null);
  assert.equal(decodeCursor(encodeCursor(["123", "item"]), isNumberStringCursor), null);
  assert.equal(decodeCursor(undefined, isNumberStringCursor), null);
});
