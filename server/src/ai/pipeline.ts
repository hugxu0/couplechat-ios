// 主人消息落库后的 AI 总调度：三线并行，均不阻塞消息发送主路径。
//
//   ┌─ 1. day-context   微段 + 作息日总览（接「今天聊了啥」）
//   ├─ 2. long-memory   结构化 Memory 批处理（接长期事实）
//   └─ 3. reply         公聊召唤 / 私聊有文字（纯图不答，等用户提问）
//
// 公聊 engagement（冲突/搭话）挂在 day-context 微段提交之后，不在本文件。

import type { Server } from "socket.io";
import type { AuthUser, ClientMessage } from "../types";
import { toStoredChannel } from "../types";
import { config } from "../config";
import { aiEnabled } from "./provider";
import { scheduleContextCatchUp } from "./conversation/context";
import { onMemoryMessage } from "./memory/extractor";
import { queueRespond, type ReplySink, type Trigger } from "./agent/replyQueue";

const AI_UNAVAILABLE_REPLY = "大橘现在没有连接 AI 模型，请检查服务端配置。";

function stripTrigger(text: string): string {
  let result = text;
  for (const alias of config.ai.triggerAliases) {
    result = result.split(alias).join(" ");
  }
  return result.replace(/\s+/g, " ").trim();
}

function isTriggered(text: string): boolean {
  return config.ai.triggerAliases.some((alias) => text.includes(alias));
}

function messageImageUrls(message: ClientMessage): string[] {
  if (message.type !== "image") return [];
  const photos = (message.attachments ?? [])
    .filter((attachment) => attachment.role === "photo" && attachment.url)
    .sort((a, b) => a.order - b.order)
    .map((attachment) => attachment.url);
  return [...new Set(photos.length ? photos : message.url ? [message.url] : [])].slice(0, 9);
}

function buildUserTrigger(
  storedChannel: string,
  user: AuthUser,
  message: ClientMessage,
  question: string,
  imageUrls: string[],
): Trigger {
  return {
    storedChannel,
    question,
    requesterName: user.name,
    requesterUsername: user.username,
    messageId: message.id,
    currentImageUrl: imageUrls[0],
    currentImageUrls: imageUrls,
    currentImageSenderName: imageUrls.length ? message.senderName : undefined,
  };
}

async function emitUnavailable(
  sink: ReplySink,
  storedChannel: string,
  user: AuthUser,
  messageId: string,
  question: string,
  withTyping: boolean,
): Promise<void> {
  const trigger = {
    storedChannel,
    question,
    requesterName: user.name,
    requesterUsername: user.username,
    messageId,
  };
  sink.activity?.(trigger, "accepted");
  sink.activity?.(trigger, "generating");
  if (withTyping) sink.typing(storedChannel, true);
  try {
    if (withTyping) await new Promise((resolve) => setTimeout(resolve, 400));
    await sink.emit(storedChannel, AI_UNAVAILABLE_REPLY, true);
    sink.activity?.(trigger, "finished");
  } catch (error) {
    sink.activity?.(trigger, "failed");
    console.warn("[ai] 不可用提示发送失败:", error instanceof Error ? error.message : error);
  } finally {
    if (withTyping) sink.typing(storedChannel, false);
  }
}

/**
 * 真人消息已持久化后的 AI 入口（fire-and-forget）。
 * @returns 是否排队了一次用户向回复（不含后台 engagement）
 */
export function dispatchAfterOwnerMessage(
  _io: Server,
  user: AuthUser,
  message: ClientMessage,
  sink: ReplySink,
): { queuedReply: boolean } {
  if (message.kind !== "user") return { queuedReply: false };

  const storedChannel = toStoredChannel(message.channel, user.username);
  const isText = message.type === "text" && message.text.trim().length > 0;
  const hasCaption = message.text.trim().length > 0;
  const imageUrls = messageImageUrls(message);
  const isImage = imageUrls.length > 0;
  if (!isText && !isImage) return { queuedReply: false };

  // ── 线 1：当日上下文（与是否召唤无关）──────────────────────────
  scheduleContextCatchUp(storedChannel);

  // ── 线 2：长期 Memory（仅文本；寒暄过滤在 extractor 内）────────
  if (isText && aiEnabled()) {
    onMemoryMessage(storedChannel);
  }

  // ── 线 3：用户向回复 ──────────────────────────────────────────
  const isPrivate = storedChannel.startsWith("ai:");
  const triggered = hasCaption && isTriggered(message.text);

  // 纯图、无说明文字：只落库/上下文，不自动分析（私聊与公聊一致等用户再问）。
  if (isImage && !hasCaption) {
    return { queuedReply: false };
  }

  if (!isPrivate) {
    // 公聊：仅明确召唤才答；无召唤时日上下文与 Memory 仍继续。
    if (!triggered) return { queuedReply: false };
    if (!aiEnabled()) {
      void emitUnavailable(
        sink,
        storedChannel,
        user,
        message.id,
        stripTrigger(message.text),
        false,
      );
      return { queuedReply: false };
    }
    // 有图必须带说明/召唤文字才会走到这里；无图召唤则只传文字。
    const question = stripTrigger(message.text) || "（只是喊了你）";
    const trigger = buildUserTrigger(storedChannel, user, message, question, imageUrls);
    sink.activity?.(trigger, "accepted");
    queueRespond(trigger, sink);
    return { queuedReply: true };
  }

  // 私聊：有文字才答（可带图说明）；纯图已在上方 return。
  if (!isText && !(isImage && hasCaption)) {
    return { queuedReply: false };
  }

  if (!aiEnabled()) {
    void emitUnavailable(
      sink,
      storedChannel,
      user,
      message.id,
      message.text.trim(),
      true,
    );
    return { queuedReply: false };
  }

  const trigger = buildUserTrigger(
    storedChannel,
    user,
    message,
    message.text.trim(),
    imageUrls,
  );
  sink.activity?.(trigger, "accepted");
  queueRespond(trigger, sink);
  return { queuedReply: true };
}
