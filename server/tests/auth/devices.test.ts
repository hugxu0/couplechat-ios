import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("one account can keep independent Bark endpoints for multiple devices", async () => {
  await withTestDatabase(async () => {
    const { run } = await import("../../src/db");
    const now = Date.now();
    await run(
      `INSERT INTO accounts
       (id, username, display_name, password_hash, avatar, status, version, created_at, updated_at)
       VALUES (?, ?, ?, ?, '', 'active', 0, ?, ?)`,
      ["acc_test_xu", "xu", "小旭", "hash", now, now],
    );
    const { createDeviceSession, listDevices, revokeDevice, saveCurrentDeviceBark } = await import("../../src/auth/devices");
    const { listBarkRecipients } = await import("../../src/push/recipients");
    const user = { username: "xu", name: "小旭", accountId: "acc_test_xu" };
    const input = {
      platform: "ios" as const,
      deviceName: "iPhone",
      appVersion: "0.2.0",
      buildNumber: "2",
      locale: "zh_CN",
      timezone: "Asia/Shanghai",
    };

    const phoneUser = await createDeviceSession(user, {
      ...input, installationId: "installation-phone",
    });
    const tabletUser = await createDeviceSession(user, {
      ...input, platform: "ipados", deviceName: "iPad",
      installationId: "installation-tablet",
    });
    assert.ok(phoneUser && tabletUser);
    const phone = await saveCurrentDeviceBark(phoneUser!, {
      ...input, installationId: "installation-phone", barkKey: "bark-phone",
    });
    const tablet = await saveCurrentDeviceBark(tabletUser!, {
      ...input, platform: "ipados", deviceName: "iPad",
      installationId: "installation-tablet", barkKey: "bark-tablet",
    });
    assert.ok(phone && tablet);
    const { createToken, verifyActiveToken } = await import("../../src/auth/token");
    const tabletToken = createToken(tabletUser!);
    assert.equal((await verifyActiveToken(tabletToken))?.deviceId, tablet!.id);
    assert.deepEqual(
      new Set((await listBarkRecipients(["xu"])).map((item) => item.barkKey)),
      new Set(["bark-phone", "bark-tablet"]),
    );

    await saveCurrentDeviceBark(phoneUser!, {
      ...input, installationId: "installation-phone", barkKey: null,
    });
    assert.deepEqual((await listBarkRecipients(["xu"])).map((item) => item.barkKey), ["bark-tablet"]);
    const devices = await listDevices(phoneUser!);
    assert.equal(devices.find((item) => item.id === phone!.id)?.barkEnabled, false);
    assert.equal(devices.find((item) => item.id === tablet!.id)?.barkEnabled, true);

    assert.equal(await revokeDevice(phoneUser!, tablet!.id), true);
    assert.deepEqual(await listBarkRecipients(["xu"]), []);
    assert.equal(await verifyActiveToken(tabletToken), null);

    // 被撤设备的旧 session 不能通过 Bark 保存接口把自己复活。
    assert.equal(await saveCurrentDeviceBark(tabletUser!, {
      ...input, platform: "ipados", deviceName: "iPad",
      installationId: "installation-tablet", barkKey: "should-not-return",
    }), null);

    // 同一个 Bark 目的地可由多个设备关联；撤销其中一个不会把 endpoint 从另一个设备搬走。
    const revivedTabletUser = await createDeviceSession(user, {
      ...input, platform: "ipados", deviceName: "iPad", installationId: "installation-tablet",
    });
    assert.ok(revivedTabletUser);
    await saveCurrentDeviceBark(phoneUser!, {
      ...input, installationId: "installation-phone", barkKey: "shared-bark",
    });
    await saveCurrentDeviceBark(revivedTabletUser!, {
      ...input, platform: "ipados", deviceName: "iPad",
      installationId: "installation-tablet", barkKey: "shared-bark",
    });
    assert.deepEqual((await listBarkRecipients(["xu"])).map((item) => item.barkKey), ["shared-bark"]);
    assert.equal(await revokeDevice(phoneUser!, revivedTabletUser!.deviceId!), true);
    assert.deepEqual((await listBarkRecipients(["xu"])).map((item) => item.barkKey), ["shared-bark"]);
  });
});
