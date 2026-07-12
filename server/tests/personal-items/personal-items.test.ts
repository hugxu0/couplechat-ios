import assert from "node:assert/strict";
import test from "node:test";
import { withTestDatabase } from "../support/postgresHarness";

test("personal items preserve owner isolation and shared visibility", async () => {
  await withTestDatabase(async () => {
    const items = await import("../../src/personalItems/itemService");
    const xu = { username: "xu", name: "小旭" };
    const si = { username: "si", name: "小偲" };
    const personal = await items.createPersonalItem(xu, { kind: "memo", title: "私有备忘" });
    const shared = await items.createPersonalItem(xu, { kind: "reminder", scope: "shared", title: "共同提醒" });

    assert.ok(personal);
    assert.ok(shared);
    assert.equal((await items.listPersonalItems(si, "memo", "personal")).length, 0);
    assert.equal((await items.listPersonalItems(si, "reminder", "shared"))[0]?.id, shared?.id);
    assert.equal((await items.updatePersonalItem(si, shared!.id, { isDone: true }))?.isDone, true);
    assert.equal(await items.deletePersonalItem(xu, personal!.id), true);
    assert.equal(await items.getPersonalItem(xu, personal!.id), null);
  });
});
