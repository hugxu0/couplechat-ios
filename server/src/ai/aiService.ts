// AI 门面：realtime 层只跟这里打交道。
// 职责：入口分流（couple 召唤 / ai 私聊每条都答）、回复入库与广播、后台任务挂钩。

import type { Server } from "socket.io";
import { socketEvents } from "../contracts/realtime";
import type { AuthUser, ClientMessage } from "../types";
import { toStoredChannel, type StoredChannel } from "../types";
import { createAiMessage } from "../chat/messageService";
import { pushCoupleMessageToUnavailableRecipients } from "../push/pushService";
import { config } from "../config";
import { aiEnabled } from "./provider";
import { loadAccounts } from "./memoryStore";
import { queueRespond, type ReplySink } from "./replyEngine";
import { onCoupleUserMessage } from "./extractor";
import { maybeUpdate as maybeUpdateSummary } from "./sessionSummary";
import { startScheduler } from "./nightly";
import { maybeCheck as maybeCheckConflict } from "./conflictDetector";
import { maybeInterject } from "./interjector";

export async function initAi(): Promise<void> {
  await loadAccounts();
  if (aiEnabled()) {
    startScheduler();
    console.log("[ai] 大橘已就位（AI 模型已配置）");
  } else {
    console.log("[ai] 未配置 AI_* 环境变量，大橘走本地兜底回复");
  }
}

// 未配置模型时的本地兜底（保持 ai 频道基本可用）。
const FALLBACK_REPLIES = [
  "喵，我在。你慢慢说，我会认真听。",
  "先抱一下。这个小空间里，你不用急着把话说完。",
  "大橘收到啦。等真正的模型接上，我就能更聪明地陪你聊天。",
  "我先把这句话放在爪子下面保管好。",
];

function fallbackReply(text: string): string {
  if (!text) return FALLBACK_REPLIES[0];
  const index = Math.abs([...text].reduce((sum, char) => sum + char.charCodeAt(0), 0)) % FALLBACK_REPLIES.length;
  return FALLBACK_REPLIES[index];
}

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

function makeSink(io: Server): ReplySink {
  const activityRoom = (storedChannel: string) => storedChannel.startsWith("ai:")
    ? `user:${storedChannel.slice(3)}`
    : "channel:couple";
  return {
    async emit(storedChannel, text, isFirst, meta) {
      const message = await createAiMessage(storedChannel as StoredChannel, text, meta);
      if (storedChannel.startsWith("ai:")) {
        io.to(`user:${storedChannel.slice(3)}`).emit(socketEvents.messageNew, message);
      } else {
        io.to("channel:couple").emit(socketEvents.messageNew, message);
        // couple 里大橘的发言也推给不在线的一方（只推第一条，不轰炸）。
        if (isFirst) void pushCoupleMessageToUnavailableRecipients(message);
      }
    },
    typing(storedChannel, value) {
      // iOS 客户端把 ai:typing 当作 ai 私聊频道的输入指示（裸 bool），
      // couple 频道的回复不发 typing，避免错误点亮私聊气泡。
      if (storedChannel.startsWith("ai:")) {
        io.to(`user:${storedChannel.slice(3)}`).emit(socketEvents.aiTyping, value);
      }
    },
    replying(storedChannel, value) {
      if (storedChannel.startsWith("ai:")) {
        io.to(`user:${storedChannel.slice(3)}`).emit(socketEvents.aiReplying, value);
      }
    },
    activity(trigger, phase) {
      io.to(activityRoom(trigger.storedChannel)).emit(socketEvents.aiActivity, {
        channel: trigger.storedChannel.startsWith("ai:") ? "ai" : "couple",
        requestMessageId: trigger.messageId,
        requesterUsername: trigger.requesterUsername,
        phase,
      });
    },
  };
}

// 收到一条真人消息后的 AI 流水线入口（fire-and-forget，绝不阻塞消息主流程）。
export function handleUserMessage(io: Server, user: AuthUser, message: ClientMessage): void {
  if (message.kind !== "user") return;
  const storedChannel = toStoredChannel(message.channel, user.username);
  const isText = message.type === "text" && message.text.trim().length > 0;
  const isImage = message.type === "image" && Boolean(message.url);
  if (!isText && !isImage) return;
  const sink = makeSink(io);

  // 滚动摘要由「收到真人消息」驱动（阈值不够会早退，近乎零成本）。
  if (aiEnabled()) {
    void maybeUpdateSummary(storedChannel).catch(() => {});
  }

  if (storedChannel === "couple") {
    if (!isText) return; // couple 频道暂不处理图片，只认文字召唤
    const triggered = isTriggered(message.text);
    if (!aiEnabled()) {
      // 配置缺失或部署切换期间，明确召唤也必须有反馈，不能静默。
      if (triggered) {
        const trigger = {
          storedChannel, question: stripTrigger(message.text), requesterName: user.name,
          requesterUsername: user.username, messageId: message.id,
        };
        sink.activity?.(trigger, "accepted");
        sink.activity?.(trigger, "generating");
        void sink.emit(storedChannel, fallbackReply(trigger.question), true)
          .then(() => sink.activity?.(trigger, "finished"))
          .catch((error) => {
            sink.activity?.(trigger, "failed");
            console.warn("[ai] couple 本地兜底发送失败:", error instanceof Error ? error.message : error);
          });
      }
      return;
    }
    onCoupleUserMessage(); // 攒够 N 条触发一次事实提取
    // 后台管道：冲突检测 + 主动插话（fire-and-forget，绝不阻塞 @召唤应答）
    void maybeCheckConflict(io, storedChannel).catch(() => {});
    void maybeInterject(io, storedChannel).catch(() => {});
    if (triggered) {
      const trigger = {
          storedChannel,
          question: stripTrigger(message.text),
          requesterName: user.name,
          requesterUsername: user.username,
          messageId: message.id,
        };
      sink.activity?.(trigger, "accepted");
      queueRespond(trigger, sink);
    }
    return;
  }

  // ai 私聊：每条文本 / 图片都答，不需要召唤。
  if (!aiEnabled()) {
    void (async () => {
      const trigger = {
        storedChannel, question: isText ? message.text.trim() : "", requesterName: user.name,
        requesterUsername: user.username, messageId: message.id,
      };
      sink.activity?.(trigger, "accepted");
      sink.activity?.(trigger, "generating");
      sink.typing(storedChannel, true);
      await new Promise((resolve) => setTimeout(resolve, 550));
      await sink.emit(storedChannel, fallbackReply(isText ? message.text.trim() : ""), true);
      sink.typing(storedChannel, false);
      sink.activity?.(trigger, "finished");
    })().catch(() => {});
    return;
  }

  // 文本 / 图片统一走一条流水线：图片消息此时已经落库，回复引擎里的意图判断
  // 会自己决定要不要识图（needImages 命中才去看最近这张图，不强求）。
  const trigger = {
      storedChannel,
      question: message.text.trim(),
      requesterName: user.name,
      requesterUsername: user.username,
      messageId: message.id,
      currentImageUrl: isImage ? message.url : undefined,
      currentImageSenderName: isImage ? message.senderName : undefined,
    };
  sink.activity?.(trigger, "accepted");
  queueRespond(trigger, sink);
}
