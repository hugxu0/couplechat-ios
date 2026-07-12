import assert from "node:assert/strict";
import test from "node:test";
import type { AuthUser } from "../../src/types";
import {
  isAvailable,
  markConnected,
  markDisconnected,
  onlineUsers,
  resetPresenceForTests,
  setAway,
} from "../../src/socket/presence";

test("presence remains available while any account device is foreground", () => {
  resetPresenceForTests();
  const user: AuthUser = { username: "alice", name: "Alice", coupleId: "couple-a" };
  const partner: AuthUser = { username: "bob", name: "Bob", coupleId: "couple-a" };
  const outsider: AuthUser = { username: "carol", name: "Carol", coupleId: "couple-b" };

  markConnected(user, "phone");
  markConnected(user, "tablet");
  markConnected(partner, "partner-phone");
  markConnected(outsider, "outsider-phone");
  setAway(user, "tablet", true);

  assert.equal(isAvailable("alice"), true);
  assert.deepEqual(onlineUsers("couple-a").sort(), ["alice", "bob"]);

  setAway(user, "phone", true);
  assert.equal(isAvailable("alice"), false);
  setAway(user, "tablet", false);
  assert.equal(isAvailable("alice"), true);

  markDisconnected(user, "tablet");
  assert.equal(isAvailable("alice"), false);
  setAway(user, "phone", false);
  assert.equal(isAvailable("alice"), true);
  assert.deepEqual(onlineUsers("couple-b"), ["carol"]);
  resetPresenceForTests();
});
