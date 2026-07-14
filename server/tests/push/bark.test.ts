import assert from "node:assert/strict";
import test from "node:test";
import { installSafeTestEnvironment } from "../support/testEnv";

installSafeTestEnvironment();

test("Bark pushes use the public CoupleChat icon by default", async () => {
  const { buildBarkPushURL } = await import("../../src/push/bark");
  const url = buildBarkPushURL("device-key", "标题", "内容");

  assert.equal(url.searchParams.get("icon"), "http://127.0.0.1:8080/assets/couplechat-icon.png");
  assert.equal(url.searchParams.get("url"), "couplechat://");
});

test("a Bark push can override its icon", async () => {
  const { buildBarkPushURL } = await import("../../src/push/bark");
  const url = buildBarkPushURL("device-key", "标题", "内容", {
    icon: "https://cdn.example.com/icon.png",
  });

  assert.equal(url.searchParams.get("icon"), "https://cdn.example.com/icon.png");
});
