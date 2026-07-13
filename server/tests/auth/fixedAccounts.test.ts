import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("authentication is limited to the two fixed accounts and onboarding routes are absent", async () => {
  await withTestDatabase(async () => {
    const { buildApp } = await import("../../src/app");
    const { run } = await import("../../src/db");
    const { ensureLegacyConversations, ensureLegacyCouple } = await import("../../src/auth/accounts");
    const { hashPassword } = await import("../../src/auth/password");
    const now = Date.now();
    for (const [username, displayName] of [["xu", "小旭"], ["si", "小偲"], ["old_user", "旧账号"]]) {
      await run(
        `INSERT INTO accounts
         (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
         VALUES (?, ?, ?, ?, '', 'active', 0, ?, ?)`,
        [`acc_test_${username}`, username, displayName, hashPassword("password-123"), now, now],
      );
    }
    await ensureLegacyCouple();
    await ensureLegacyConversations();

    const app = await buildApp();
    const accounts = await app.inject({ method: "GET", url: "/api/accounts" });
    assert.deepEqual(accounts.json().map((item: { username: string }) => item.username), ["xu", "si"]);

    const device = {
      installationId: "fixed-account-test-device",
      platform: "ios",
      deviceName: "iPhone",
      appVersion: "1.0",
      buildNumber: "1",
      locale: "zh_CN",
      timezone: "Asia/Shanghai",
    };
    const login = await app.inject({
      method: "POST",
      url: "/api/v2/login",
      payload: { username: "xu", password: "password-123", device },
    });
    assert.equal(login.statusCode, 200, login.body);
    assert.equal(Object.hasOwn(login.json(), "paired"), false);

    const retiredAccount = await app.inject({
      method: "POST",
      url: "/api/v2/login",
      payload: { username: "old_user", password: "password-123", device },
    });
    assert.equal(retiredAccount.statusCode, 401);

    for (const request of [
      { method: "POST", url: "/api/v2/register" },
      { method: "POST", url: "/api/v2/couples" },
      { method: "POST", url: "/api/v2/couples/invites" },
      { method: "POST", url: "/api/v2/couples/join" },
      { method: "GET", url: "/api/v2/me/couple" },
    ] as const) {
      const response = await app.inject(request);
      assert.equal(response.statusCode, 404, `${request.method} ${request.url} should not exist`);
    }
    await app.close();
  });
});
