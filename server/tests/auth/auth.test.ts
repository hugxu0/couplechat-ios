import assert from "node:assert/strict";
import test from "node:test";
import { installSafeTestEnvironment } from "../support/testEnv";

installSafeTestEnvironment();

test("password hashes verify without exposing the original password", async () => {
  const { hashPassword, verifyPassword } = await import("../../src/auth/password");
  const hash = hashPassword("correct horse battery staple");
  assert.match(hash, /^scrypt\$/);
  assert.equal(verifyPassword("correct horse battery staple", hash), true);
  assert.equal(verifyPassword("wrong password", hash), false);
  assert.equal(verifyPassword("anything", "legacy-plaintext"), false);
});

test("tokens reject tampering and expiry", async () => {
  const { createToken, verifyToken } = await import("../../src/auth/token");
  const user = { username: "xu", name: "小旭" };
  const token = createToken(user, 1);
  assert.deepEqual(verifyToken(token), user);
  assert.equal(verifyToken(`${token}x`), null);
  assert.equal(verifyToken(createToken(user, -1)), null);
});
