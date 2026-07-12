import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("registered couples are isolated across messages, shared data and deletion sync", async () => {
  await withTestDatabase(async () => {
    const { buildApp } = await import("../../src/app");
    const app = await buildApp();
    const device = (name: string) => ({
      installationId: `installation-${name}`,
      platform: "ios",
      deviceName: name,
      appVersion: "0.2.0",
      buildNumber: "2",
      locale: "zh_CN",
      timezone: "Asia/Shanghai",
    });
    const register = async (username: string) => {
      const response = await app.inject({
        method: "POST",
        url: "/api/v2/register",
        payload: { username, displayName: username, password: "password-123", device: device(username) },
      });
      assert.equal(response.statusCode, 201, response.body);
      const body = response.json() as { token: string; paired: boolean };
      assert.equal(body.paired, false);
      return body.token;
    };
    const missingRegisterDevice = await app.inject({
      method: "POST",
      url: "/api/v2/register",
      payload: { username: "no_device", displayName: "no_device", password: "password-123" },
    });
    assert.equal(missingRegisterDevice.statusCode, 400, missingRegisterDevice.body);
    const aliceToken = await register("alice");
    const missingLoginDevice = await app.inject({
      method: "POST",
      url: "/api/v2/login",
      payload: { username: "alice", password: "password-123" },
    });
    assert.equal(missingLoginDevice.statusCode, 400, missingLoginDevice.body);
    const v2Login = await app.inject({
      method: "POST",
      url: "/api/v2/login",
      payload: { username: "alice", password: "password-123", device: device("alice-ipad") },
    });
    assert.equal(v2Login.statusCode, 200, v2Login.body);
    assert.equal((v2Login.json() as { paired: boolean }).paired, false);
    const bobToken = await register("bob_user");
    const carolToken = await register("carol");

    const aliceCouple = await app.inject({
      method: "POST", url: "/api/v2/couples",
      headers: { authorization: `Bearer ${aliceToken}` }, payload: { name: "A+B" },
    });
    assert.equal(aliceCouple.statusCode, 201, aliceCouple.body);
    const aliceCoupleBody = aliceCouple.json() as { coupleId: string; invite: { code: string } };
    assert.match(aliceCoupleBody.invite.code, /^[A-HJ-NP-Z2-9]{8}$/);
    const join = await app.inject({
      method: "POST", url: "/api/v2/couples/join",
      headers: { authorization: `Bearer ${bobToken}` },
      payload: { code: aliceCoupleBody.invite.code },
    });
    assert.equal(join.statusCode, 200, join.body);

    const aliceMe = await app.inject({
      method: "GET", url: "/api/me", headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.equal(aliceMe.statusCode, 200, aliceMe.body);
    assert.equal((aliceMe.json() as { paired: boolean }).paired, true);
    const aliceAccounts = await app.inject({
      method: "GET", url: "/api/accounts", headers: { authorization: `Bearer ${aliceToken}` },
    });
    assert.deepEqual(
      (aliceAccounts.json() as Array<{ username: string }>).map((account) => account.username),
      ["alice", "bob_user"],
    );

    const carolCouple = await app.inject({
      method: "POST", url: "/api/v2/couples",
      headers: { authorization: `Bearer ${carolToken}` }, payload: { name: "C" },
    });
    assert.equal(carolCouple.statusCode, 201, carolCouple.body);

    const { verifyActiveToken } = await import("../../src/auth/token");
    const alice = await verifyActiveToken(aliceToken);
    const bob = await verifyActiveToken(bobToken);
    const carol = await verifyActiveToken(carolToken);
    assert.ok(alice?.coupleId && bob?.coupleId && carol?.coupleId);
    assert.equal(alice!.coupleId, bob!.coupleId);
    assert.notEqual(alice!.coupleId, carol!.coupleId);

    const { createAiMessage, createMessage, fetchMessages, recallMessage } = await import("../../src/chat/messageService");
    await createAiMessage("ai:alice", "alice private daju", undefined, alice!);
    await createAiMessage("couple", "alice and bob daju", undefined, alice!);
    assert.deepEqual((await fetchMessages(alice!, { channel: "ai" })).map((item) => item.text),
      ["alice private daju"]);
    assert.deepEqual((await fetchMessages(bob!, { channel: "ai" })).map((item) => item.text), []);
    assert.deepEqual((await fetchMessages(bob!, { channel: "couple" })).map((item) => item.text),
      ["alice and bob daju"]);
    assert.deepEqual((await fetchMessages(carol!, { channel: "couple" })).map((item) => item.text), []);
    const aliceMessage = await createMessage(alice!, {
      channel: "couple", type: "text", text: "only alice and bob", clientId: "alice-1",
    });
    await createMessage(carol!, {
      channel: "couple", type: "text", text: "only carol", clientId: "carol-1",
    });
    assert.deepEqual((await fetchMessages(bob!, { channel: "couple" })).map((item) => item.text),
      ["alice and bob daju", "only alice and bob"]);
    assert.deepEqual((await fetchMessages(carol!, { channel: "couple" })).map((item) => item.text),
      ["only carol"]);

    const items = await import("../../src/personalItems/itemService");
    await items.createPersonalItem(alice!, { kind: "memo", scope: "shared", title: "AB shared" });
    await items.createPersonalItem(carol!, { kind: "memo", scope: "shared", title: "C shared" });
    assert.deepEqual((await items.listPersonalItems(bob!, "memo", "shared")).map((item) => item.title),
      ["AB shared"]);
    assert.deepEqual((await items.listPersonalItems(carol!, "memo", "shared")).map((item) => item.title),
      ["C shared"]);

    const shared = await import("../../src/shared/sharedService");
    await shared.setSharedItem(alice!, "theme", { value: "peach" });
    await shared.setSharedItem(carol!, "theme", { value: "blue" });
    assert.deepEqual((await shared.getSharedState(bob!)).theme?.value, { value: "peach" });
    assert.deepEqual((await shared.getSharedState(carol!)).theme?.value, { value: "blue" });

    assert.equal((await recallMessage(alice!, aliceMessage.id))?.deleted, true);
    const bobSync = await app.inject({
      method: "GET", url: "/api/v2/sync?cursor=0",
      headers: { authorization: `Bearer ${bobToken}` },
    });
    const carolSync = await app.inject({
      method: "GET", url: "/api/v2/sync?cursor=0",
      headers: { authorization: `Bearer ${carolToken}` },
    });
    const bobEvents = bobSync.json().events as Array<{ entityId: string; operation: string }>;
    const carolEvents = carolSync.json().events as Array<{ entityId: string; operation: string }>;
    assert.ok(bobEvents.some((event) => event.entityId === aliceMessage.id && event.operation === "delete"));
    assert.ok(!carolEvents.some((event) => event.entityId === aliceMessage.id));
    await app.close();
  });
});
