import assert from "node:assert/strict";
import test from "node:test";
import { domainEvents } from "../../src/events/domainEvents";

test("domain events notify subscribers and support disposal", async () => {
  const received: string[] = [];
  const dispose = domainEvents.subscribe("message.recalled", ({ messageId }) => {
    received.push(messageId);
  });
  await domainEvents.publish("message.recalled", { messageId: "msg_one" });
  dispose();
  await domainEvents.publish("message.recalled", { messageId: "msg_two" });
  assert.deepEqual(received, ["msg_one"]);
});
