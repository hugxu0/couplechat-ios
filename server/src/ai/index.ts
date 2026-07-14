// AI 门面：realtime 层只跟这里打交道。
// 职责：入口分流（couple 召唤 / ai 私聊每条都答）、回复入库与广播、后台任务挂钩。

import type { Server } from "socket.io";
import { socketEvents } from "../contracts/realtime";
import type { AuthUser, ClientMessage } from "../types";
import { toStoredChannel, type StoredChannel } from "../types";
import { createAiMessage } from "../chat/messageService";
import {
  pushCoupleMessageToUnavailableRecipients,
  pushPrivateAiMessageToUnavailableRecipient,
} from "../push/pushService";
import { config } from "../config";
import { aiEnabled } from "./provider";
import { loadAccounts } from "./accounts";
import { queueRespond, type ReplySink } from "./agent/replyQueue";
import { agentRuntimeEnabled } from "./agent/runtime";
import {
  initializeMemory,
  onMemoryMessage,
  setMemoryEngagementHandler,
  type MemoryEngagementSignal,
} from "./memory/extractor";
import { updateConversationContext } from "./conversation/context";
import { startDailyScheduler, stopDailyScheduler } from "./background/dailyScheduler";
import { startMemoryMaintenance, stopMemoryMaintenance } from "./memory/maintenance";
import { subscribeMemoryDomainEvents } from "./memory/events";

const engagementCooldowns: Record<MemoryEngagementSignal["kind"], number> = {
  conflict: 15 * 60 * 1000,
  interject: 2 * 60 * 60 * 1000,
};
const lastEngagementAt: Partial<Record<MemoryEngagementSignal["kind"], number>> = {};
let activeIo: Server | null = null;
let pendingEngagement: MemoryEngagementSignal | null = null;
let stopMemoryEvents: (() => void) | null = null;

export async function initAi(): Promise<void> {
  stopMemoryEvents ??= subscribeMemoryDomainEvents();
  await loadAccounts();
  setMemoryEngagementHandler((signal) => {
    if (activeIo) handleMemoryEngagement(activeIo, signal);
    else pendingEngagement = signal;
  });
  await initializeMemory();
  if (config.scheduledJobsEnabled) startMemoryMaintenance();
  if (aiEnabled()) {
    if (config.scheduledJobsEnabled) startDailyScheduler();
    console.log("[ai] 大橘已就位（AI 模型已配置）");
    console.log(`[ai] Agent + MCP ${agentRuntimeEnabled() ? "已就绪" : "不可用，请检查模型兼容性"}`);
  } else {
    console.log("[ai] 未配置 AI_* 环境变量，大橘走本地兜底回复");
  }
}

export function shutdownAi(): void {
  stopDailyScheduler();
  stopMemoryMaintenance();
  stopMemoryEvents?.();
  stopMemoryEvents = null;
  activeIo = null;
  pendingEngagement = null;
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

function makeSink(io: Server, user?: AuthUser): ReplySink {
  const accountRoom = `account:${user?.accountId ?? user?.username ?? "unknown"}`;
  const coupleRoom = `couple:${user?.coupleId ?? "cpl_legacy_xusi"}`;
  const activityRoom = (storedChannel: string) => storedChannel.startsWith("ai:")
    ? accountRoom
    : coupleRoom;
  return {
    async emit(storedChannel, text, isFirst, meta) {
      const message = await createAiMessage(storedChannel as StoredChannel, text, meta, user);
      if (storedChannel.startsWith("ai:")) {
        io.to(accountRoom).emit(socketEvents.messageNew, message);
        if (isFirst) void pushPrivateAiMessageToUnavailableRecipient(message, user?.username);
      } else {
        io.to(coupleRoom).emit(socketEvents.messageNew, message);
        // couple 里大橘的发言也推给不在线的一方（只推第一条，不轰炸）。
        if (isFirst) void pushCoupleMessageToUnavailableRecipients(
          message,
          user?.coupleId ?? "cpl_legacy_xusi",
        );
      }
    },
    typing(storedChannel, value) {
      // iOS 客户端把 ai:typing 当作 ai 私聊频道的输入指示（裸 bool），
      // couple 频道的回复不发 typing，避免错误点亮私聊气泡。
      if (storedChannel.startsWith("ai:")) {
        io.to(accountRoom).emit(socketEvents.aiTyping, value);
      }
    },
    replying(storedChannel, value) {
      if (storedChannel.startsWith("ai:")) {
        io.to(accountRoom).emit(socketEvents.aiReplying, value);
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

export function setAiSocketIO(io: Server): void {
  activeIo = io;
  if (pendingEngagement) {
    const signal = pendingEngagement;
    pendingEngagement = null;
    handleMemoryEngagement(io, signal);
  }
}

function handleMemoryEngagement(io: Server, signal: MemoryEngagementSignal): void {
  const now = Date.now();
  const lastAt = lastEngagementAt[signal.kind] ?? 0;
  if (now - lastAt < engagementCooldowns[signal.kind]) return;
  lastEngagementAt[signal.kind] = now;
  const trigger = {
    storedChannel: "couple",
    question: signal.kind === "conflict" ? "后台冲突介入候选" : "后台主动搭话候选",
    requesterName: signal.requesterName,
    requesterUsername: signal.requesterUsername,
    origin: signal.kind,
    backgroundReason: signal.reason,
    backgroundContext: signal.context,
  } as const;
  const result = queueRespond(trigger, makeSink(io));
  console.log(
    `[ai] 30条批处理提交 ${signal.kind} Agent 候选 confidence=${signal.confidence.toFixed(2)} queue=${result}`,
  );
}

// 收到一条真人消息后的 AI 流水线入口（fire-and-forget，绝不阻塞消息主流程）。
export function handleUserMessage(io: Server, user: AuthUser, message: ClientMessage): void {
  if (message.kind !== "user") return;
  const storedChannel = toStoredChannel(message.channel, user.username);
  const isText = message.type === "text" && message.text.trim().length > 0;
  const isImage = message.type === "image" && Boolean(message.url);
  if (!isText && !isImage) return;
  const sink = makeSink(io, user);

  if (isText && aiEnabled()) {
    onMemoryMessage(storedChannel);
    void updateConversationContext(storedChannel).catch(() => undefined);
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

  // 文本和图片统一交给 Agent；图片是否需要识别由 Agent 选择工具。
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
