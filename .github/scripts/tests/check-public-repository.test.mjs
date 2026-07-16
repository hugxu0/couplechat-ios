import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyTrackedPath,
  scanTrackedText,
} from "../check-public-repository.mjs";

test("allows example env files and rejects deployable env files", () => {
  assert.deepEqual(classifyTrackedPath("server/.env.production.example"), []);
  assert.equal(
    classifyTrackedPath("server/.env.production")[0]?.category,
    "non-example-environment-file",
  );
});

test("rejects signing, backup, and UDID file names", () => {
  assert.equal(
    classifyTrackedPath("private/signing" + ".p12")[0]?.category,
    "signing-or-private-key-file",
  );
  assert.equal(
    classifyTrackedPath("private/database" + ".dump")[0]?.category,
    "backup-or-build-artifact",
  );
  assert.equal(
    classifyTrackedPath("private/device-" + "udid.txt")[0]?.category,
    "device-udid-file",
  );
});

test("reports secret categories without returning matched values", () => {
  const privateKey = "-----BEGIN " + "OPENSSH PRIVATE KEY-----";
  const token = "gh" + "p_" + "A".repeat(36);
  const udid = "UDID=" + "a".repeat(40);
  const categories = scanTrackedText(
    "fixture.txt",
    [privateKey, token, udid].join("\n"),
  ).map(({ category }) => category);

  assert.ok(categories.includes("private-key-header"));
  assert.ok(categories.includes("high-confidence-token"));
  assert.ok(categories.includes("device-udid-value"));
});

test("allows loopback and unspecified binds but rejects external IPv4", () => {
  assert.deepEqual(scanTrackedText("loopback.txt", "127.0.0.1 0.0.0.0"), []);
  const externalAddress = "198.51.100" + ".42";
  assert.equal(
    scanTrackedText("external.txt", externalAddress)[0]?.category,
    "non-loopback-ipv4-literal",
  );
});
