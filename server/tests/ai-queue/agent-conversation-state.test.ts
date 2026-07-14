import assert from "node:assert/strict";
import test from "node:test";
import type { LogMessage } from "../../src/ai/conversation/log";
import { installSafeTestEnvironment } from "../support/testEnv";

installSafeTestEnvironment();

function message(id: string, ts: number, overrides: Partial<LogMessage> = {}): LogMessage {
  return {
    id,
    sender: "xu",
    senderName: "小旭",
    kind: "user",
    type: "text",
    text: id,
    url: null,
    attachments: [],
    ts,
    ...overrides,
  };
}

test("50 raw messages are split into 42 supplemental and 8 focus messages", async () => {
  const {
    CONVERSATION_FOCUS_MESSAGES,
    CONVERSATION_MAX_MESSAGES,
    selectConversationMessages,
    splitConversationMessages,
  } = await import("../../src/ai/conversation/context");
  const messages = Array.from({ length: 60 }, (_, index) => message(`msg_${index}`, index));
  const selected = selectConversationMessages(messages);
  const split = splitConversationMessages(selected);

  assert.equal(selected.length, CONVERSATION_MAX_MESSAGES);
  assert.equal(split.focus.length, CONVERSATION_FOCUS_MESSAGES);
  assert.equal(split.supplemental.length, 42);
  assert.equal(split.focus[0].id, "msg_52");
  assert.equal(split.focus.at(-1)?.id, "msg_59");
});

test("multi-photo messages preserve photo order and ignore paired Live Photo videos", async () => {
  const { imageUrls } = await import("../../src/ai/conversation/log");
  const item = message("album", 1, {
    type: "image",
    url: "/media/first",
    attachments: [
      { id: "video", assetId: "asset_a", role: "pairedVideo", order: 0, url: "/media/video", mimeType: "video/quicktime", size: 2 },
      { id: "second", assetId: "asset_b", role: "photo", order: 1, url: "/media/second", mimeType: "image/jpeg", size: 1 },
      { id: "first", assetId: "asset_a", role: "photo", order: 0, url: "/media/first", mimeType: "image/jpeg", size: 1 },
    ],
  });

  assert.deepEqual(imageUrls(item), ["/media/first", "/media/second"]);
});

test("recent image lookup returns the latest consecutive image group instead of one image", async () => {
  const { latestImageGroup } = await import("../../src/ai/conversation/log");
  const messages = [
    message("old", 1, { type: "image", url: "/media/old" }),
    message("boundary", 2),
    message("first", 3, { type: "image", url: "/media/one" }),
    message("album", 4, {
      type: "image",
      url: "/media/two",
      attachments: [
        { id: "two", assetId: "two", role: "photo", order: 0, url: "/media/two", mimeType: "image/jpeg", size: 1 },
        { id: "three", assetId: "three", role: "photo", order: 1, url: "/media/three", mimeType: "image/jpeg", size: 1 },
      ],
    }),
  ];

  const group = latestImageGroup(messages, 9);
  assert.deepEqual(group.messages.map((item) => item.id), ["first", "album"]);
  assert.deepEqual(group.urls, ["/media/one", "/media/two", "/media/three"]);
});

test("public context keeps the latest 50 raw messages even when an older session was summarized", async () => {
  const { selectConversationMessages } = await import("../../src/ai/conversation/context");
  const messages = Array.from({ length: 60 }, (_, index) => message(`msg_${String(index).padStart(2, "0")}`, index));

  const selected = selectConversationMessages(messages, { upToTs: 55, upToId: "msg_55" }, undefined, false);
  assert.equal(selected.length, 50);
  assert.equal(selected[0].id, "msg_10");
  assert.equal(selected.at(-1)?.id, "msg_59");
});

test("private rolling summary removes covered raw messages and retains later messages", async () => {
  const { selectConversationMessages } = await import("../../src/ai/conversation/context");
  const messages = Array.from({ length: 50 }, (_, index) => message(`msg_${String(index).padStart(2, "0")}`, index));

  const selected = selectConversationMessages(messages, { upToTs: 41, upToId: "msg_41" }, undefined, true);
  assert.deepEqual(selected.map((item) => item.id), [
    "msg_42", "msg_43", "msg_44", "msg_45", "msg_46", "msg_47", "msg_48", "msg_49",
  ]);
});

test("private compression starts at 50 messages, summarizes 42 and leaves 8 raw", async () => {
  const { messagesReadyForRollingSummary } = await import("../../src/ai/conversation/context");
  const cursor = { upToTs: 0, upToId: "" };
  const fortyNine = Array.from({ length: 49 }, (_, index) => message(`msg_${String(index + 1).padStart(2, "0")}`, index + 1));
  const fifty = [...fortyNine, message("msg_50", 50)];

  assert.equal(messagesReadyForRollingSummary(fortyNine, cursor).length, 0);
  const compressible = messagesReadyForRollingSummary(fifty, cursor);
  assert.equal(compressible.length, 42);
  assert.equal(compressible[0].id, "msg_01");
  assert.equal(compressible.at(-1)?.id, "msg_42");
});

test("system and current messages are excluded while both owners and AI remain", async () => {
  const { selectConversationMessages } = await import("../../src/ai/conversation/context");
  const messages = [
    message("owner_one", 1),
    message("system", 2, { kind: "system" }),
    message("ai", 3, { sender: "ai", senderName: "大橘" }),
    message("current", 4, { sender: "si", senderName: "小偲" }),
  ];

  assert.deepEqual(
    selectConversationMessages(messages, undefined, "current").map((item) => item.sender),
    ["xu", "ai"],
  );
});

test("rendered context explicitly marks summary, supplemental and focus priority", async () => {
  const { conversationContextText } = await import("../../src/ai/conversation/context");
  const supplemental = [message("older", 1)];
  const focus = [message("newer", 2)];
  const text = conversationContextText({
    summary: "上次和大橘聊到旅行计划",
    supplemental,
    focus,
    recent: [...supplemental, ...focus],
    turnCount: 0,
  });

  assert.match(text, /跨会话滚动摘要/);
  assert.match(text, /辅助背景：较早原文，优先级较低/);
  assert.match(text, /重点上下文：最近 8 条原文/);
  assert.ok(text.indexOf("辅助背景") < text.indexOf("重点上下文"));
});
