import assert from "node:assert/strict";
import test from "node:test";
import { sendMessageSchema } from "../../src/contracts/realtime";

test("message schema requires server-owned media references", () => {
  assert.equal(sendMessageSchema.safeParse({ channel: "couple", type: "text", text: "hello" }).success, true);
  assert.equal(sendMessageSchema.safeParse({ channel: "couple", type: "image", text: "[图片]" }).success, false);
  assert.equal(sendMessageSchema.safeParse({
    channel: "couple",
    type: "image",
    text: "[图片]",
    uploadId: "up_media_12345678",
  }).success, true);
});

test("message schema keeps only the current flattened reply fields", () => {
  const current = sendMessageSchema.parse({
    channel: "couple",
    type: "text",
    text: "reply",
    replyTo: "msg_source",
    replyPreview: "hello",
  });
  assert.equal(current.replyTo, "msg_source");
  assert.equal(current.replyPreview, "hello");

  const old = sendMessageSchema.parse({
    channel: "couple",
    type: "text",
    text: "reply",
    reply: { id: "msg_source", preview: "hello" },
  });
  assert.equal(old.replyTo, undefined);
  assert.equal(old.replyPreview, undefined);
  assert.equal("reply" in old, false);
});

test("album attachments allow photos and reject duplicate upload references", () => {
  const valid = {
    channel: "couple",
    type: "image",
    text: "[实况照片]",
    attachments: [
      { assetId: "asset_1", role: "photo", uploadId: "up_photo_12345678", order: 0 },
      { assetId: "asset_1", role: "pairedVideo", uploadId: "up_video_12345678", order: 0 },
    ],
  };
  assert.equal(sendMessageSchema.safeParse(valid).success, true);
  assert.equal(sendMessageSchema.safeParse({ ...valid, attachments: [valid.attachments[0]] }).success, true);
  assert.equal(sendMessageSchema.safeParse({
    ...valid,
    attachments: [valid.attachments[0], { ...valid.attachments[1], uploadId: valid.attachments[0].uploadId }],
  }).success, false);
});
