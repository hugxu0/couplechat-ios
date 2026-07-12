import assert from "node:assert/strict";
import test from "node:test";
import { shutdownServer } from "../../src/lifecycle/shutdown";

test("shutdown stops producers before sockets and database", async () => {
  const order: string[] = [];
  await shutdownServer({
    stopSchedulers: () => { order.push("schedulers"); },
    stopUploadCleanup: () => { order.push("uploads"); },
    closeSocket: async () => { order.push("socket"); },
    closeHttp: async () => { order.push("http"); },
    closeDatabase: async () => { order.push("database"); },
  });
  assert.deepEqual(order, ["schedulers", "uploads", "socket", "http", "database"]);
});
