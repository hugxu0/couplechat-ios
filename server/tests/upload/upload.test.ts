import assert from "node:assert/strict";
import test from "node:test";
import { installSafeTestEnvironment } from "../support/testEnv";

installSafeTestEnvironment();

test("media signatures are bound to one upload id", async () => {
  const { signMediaId, signedMediaURL, verifyMediaSignature } = await import("../../src/upload/mediaAccess");
  const id = "up_media_12345678";
  const signature = signMediaId(id);
  assert.equal(verifyMediaSignature(id, signature), true);
  assert.equal(verifyMediaSignature("up_other_12345678", signature), false);
  const url = new URL(signedMediaURL(id));
  assert.equal(url.pathname, `/media/${id}`);
  assert.equal(url.searchParams.get("sig"), signature);
});
