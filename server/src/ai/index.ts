// AI 门面：realtime 层只跟这里打交道。
//
// 主人消息落库后 → dispatchAfterOwnerMessage（三线并行，见 pipeline.ts）
// 大橘回复入库与广播 → makeSink
// 后台冲突/搭话 → engagement 模块命中后经本文件排队 Agent

import type { Server } from "socket.io";
import { socketEvents } from "../contracts/realtime";
import type { AuthUser, ClientMessage } from "../types";
import { type StoredChannel } from "../types";
import { createAiMessage, createAiMessages, fetchMessageById } from "../chat/messageService";
import {
  pushCoupleMessageToUnavailableRecipients,
  pushPrivateAiMessageToUnavailableRecipient,
} from "../push/pushService";
import { config } from "../config";
import { aiEnabled } from "./provider";
import { loadAccounts } from "./accounts";
import {
  hasQueuedReplyForMessage,
  queueRespond,
  shutdownReplyQueue,
  startReplyQueue,
  subscribeReplyDomainEvents,
  type ReplySink,
} from "./agent/replyQueue";
import { agentRuntimeEnabled } from "./agent/runtime";
import { initializeMemory, shutdownMemoryExtraction } from "./memory/extractor";
import { startMemoryMaintenance, stopMemoryMaintenance } from "./memory/maintenance";
import { subscribeMemoryDomainEvents } from "./memory/events";
import { setEngagementHandler, type EngagementSignal } from "./engagement";
import { dispatchAfterOwnerMessage } from "./pipeline";
import { PACE } from "./settings";
import {
  markMissingAiReplyJobCancelled,
  recoverableAiReplyJobs,
  releaseAiReplyJobLeases,
} from "./agent/replyJobs";
import {
  scheduleContextCatchUp,
  shutdownConversationContext,
  startConversationContext,
} from "./conversation/context";
import { recoverInterruptedConfirmations } from "./actions/personalItems";

let activeIo: Server | null = null;
let pendingEngagement: EngagementSignal | null = null;
let stopMemoryEvents: (() => void) | null = null;
let stopReplyEvents: (() => void) | null = null;
let replyRecoveryTimer: NodeJS.Timeout | null = null;
let replyRecoveryRun: Promise<void> | null = null;
const REPLY_RECOVERY_INTERVAL_MS = 30_000;

export async function initAi(): Promise<void> {
  startReplyQueue();
  startConversationContext();
  stopMemoryEvents ??= subscribeMemoryDomainEvents();
  stopReplyEvents ??= subscribeReplyDomainEvents();
  await loadAccounts();
  const recoveredConfirmations = await recoverInterruptedConfirmations();
  if (recoveredConfirmations > 0) {
    console.warn(
      `[ai-confirm] 启动时安全收敛 ${recoveredConfirmations} 个中断的 confirmation`,
    );
  }
  setEngagementHandler((signal) => {
    if (activeIo) submitEngagementReply(activeIo, signal);
    else pendingEngagement = signal;
  });
  await initializeMemory();
  if (config.scheduledJobsEnabled) startMemoryMaintenance();
  if (aiEnabled()) {
    console.log("[ai] 大橘已就位（AI 模型已配置）");
    console.log(`[ai] Agent + MCP ${agentRuntimeEnabled() ? "已就绪" : "不可用，请检查模型兼容性"}`);
  } else {
    console.log("[ai] 未配置 AI_* 环境变量，大橘只返回不可用提示");
  }
}

export async function shutdownAi(): Promise<void> {
  setEngagementHandler(null);
  activeIo = null;
  if (replyRecoveryTimer) clearInterval(replyRecoveryTimer);
  replyRecoveryTimer = null;
  await replyRecoveryRun?.catch(() => undefined);
  pendingEngagement = null;
  stopMemoryMaintenance();
  stopMemoryEvents?.();
  stopMemoryEvents = null;
  stopReplyEvents?.();
  stopReplyEvents = null;
  const [replyStopped, contextStopped, memoryStopped] = await Promise.all([
    shutdownReplyQueue(),
    shutdownConversationContext(),
    shutdownMemoryExtraction(),
  ]);
  if (!replyStopped || !contextStopped || !memoryStopped) {
    console.warn("[ai] shutdown 超时，部分后台任务未在期限内退出");
  }
}

function makeSink(io: Server, user?: AuthUser): ReplySink {
  const accountRoom = `account:${user?.accountId ?? user?.username ?? "unknown"}`;
  const coupleRoom = `couple:${user?.coupleId ?? "cpl_legacy_xusi"}`;
  const activityRoom = (storedChannel: string) => (storedChannel.startsWith("ai:")
    ? accountRoom
    : coupleRoom);
  return {
    async emit(storedChannel, text, isFirst, meta, triggerMessageId) {
      const message = await createAiMessage(
        storedChannel as StoredChannel,
        text,
        meta,
        user,
        isFirst ? triggerMessageId : undefined,
      );
      // 大橘发言也推进日上下文，便于后续总览含「大橘说过什么」。
      scheduleContextCatchUp(storedChannel);
      if (storedChannel.startsWith("ai:")) {
        io.to(accountRoom).emit(socketEvents.messageNew, message);
        if (isFirst) {
          void pushPrivateAiMessageToUnavailableRecipient(message, user?.username)
            .catch((error) => {
              console.warn(
                `[push.ai_private] 后台任务失败: ${error instanceof Error ? error.message : String(error)}`,
              );
            });
        }
      } else {
        io.to(coupleRoom).emit(socketEvents.messageNew, message);
        if (isFirst) {
          void pushCoupleMessageToUnavailableRecipients(
            message,
            user?.coupleId ?? "cpl_legacy_xusi",
          ).catch((error) => {
            console.warn(
              `[push.ai_couple] 后台任务失败: ${error instanceof Error ? error.message : String(error)}`,
            );
          });
        }
      }
    },
    async emitBatch(storedChannel, parts, triggerMessageId) {
      const messages = await createAiMessages(
        storedChannel as StoredChannel,
        parts,
        user,
        triggerMessageId,
      );
      scheduleContextCatchUp(storedChannel);
      for (let index = 0; index < messages.length; index += 1) {
        if (index > 0) {
          await new Promise((resolve) => setTimeout(
            resolve,
            PACE.replyGapMinMs + Math.floor(Math.random() * PACE.replyGapJitterMs),
          ));
        }
        const message = messages[index];
        if (storedChannel.startsWith("ai:")) {
          io.to(accountRoom).emit(socketEvents.messageNew, message);
        } else {
          io.to(coupleRoom).emit(socketEvents.messageNew, message);
        }
      }
      const first = messages[0];
      if (storedChannel.startsWith("ai:")) {
        void pushPrivateAiMessageToUnavailableRecipient(first, user?.username)
          .catch((error) => {
            console.warn(
              `[push.ai_private] 后台任务失败: ${error instanceof Error ? error.message : String(error)}`,
            );
          });
      } else {
        void pushCoupleMessageToUnavailableRecipients(
          first,
          user?.coupleId ?? "cpl_legacy_xusi",
        ).catch((error) => {
          console.warn(
            `[push.ai_couple] 后台任务失败: ${error instanceof Error ? error.message : String(error)}`,
          );
        });
      }
    },
    typing(storedChannel, value) {
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
  if (!replyRecoveryTimer) {
    replyRecoveryTimer = setInterval(() => {
      void recoverAiReplyJobs(io).catch((error) => {
        console.warn(
          "[ai] 持久化回复周期恢复失败:",
          error instanceof Error ? error.message : error,
        );
      });
    }, REPLY_RECOVERY_INTERVAL_MS);
    replyRecoveryTimer.unref();
  }
  if (pendingEngagement) {
    const signal = pendingEngagement;
    pendingEngagement = null;
    submitEngagementReply(io, signal);
  }
}

/**
 * Requeue durable user-triggered replies left behind by a process crash or a
 * graceful stop. The original message is fetched through the normal
 * conversation-scoped mapper so attachment URLs and authorization stay
 * consistent with ordinary sync responses.
 */
export async function recoverAiReplyJobs(
  io: Server,
  forceLeaseRelease = false,
): Promise<void> {
  if (replyRecoveryRun) return replyRecoveryRun;
  const run = (async () => {
    await releaseAiReplyJobLeases(forceLeaseRelease);
    const jobs = await recoverableAiReplyJobs(2_000);
    const eligible = jobs.filter(
      (job) => !hasQueuedReplyForMessage(job.triggerMessageId),
    );
    if (!eligible.length) return;
    console.warn(`[ai] 恢复 ${eligible.length} 个持久化回复任务`);
    for (const job of eligible) {
      try {
        const message = await fetchMessageById(job.user, job.channel, job.triggerMessageId);
        if (
          !message
          || message.kind !== "user"
          || message.sender !== job.user.username
          || message.id !== job.triggerMessageId
        ) {
          await markMissingAiReplyJobCancelled(job.triggerMessageId);
          continue;
        }
        await dispatchAfterOwnerMessage(io, job.user, message, makeSink(io, job.user));
      } catch (error) {
        console.warn(
          `[ai] 持久化回复恢复失败 message=${job.triggerMessageId}:`,
          error instanceof Error ? error.message : error,
        );
      }
    }
  })();
  replyRecoveryRun = run;
  try {
    await run;
  } finally {
    if (replyRecoveryRun === run) replyRecoveryRun = null;
  }
}

function submitEngagementReply(io: Server, signal: EngagementSignal): void {
  const trigger = {
    storedChannel: "couple" as const,
    question: signal.kind === "conflict" ? "后台冲突介入候选" : "后台主动搭话候选",
    requesterName: signal.requesterName,
    requesterUsername: signal.requesterUsername,
    origin: signal.kind,
    backgroundReason: signal.reason,
    backgroundContext: signal.context,
  };
  const result = queueRespond(trigger, makeSink(io));
  console.log(
    `[ai] engagement→Agent kind=${signal.kind} ` +
      `conf=${signal.confidence.toFixed(2)} queue=${result}`,
  );
}

/** 真人消息已写入后的 AI 入口（不阻塞 message.send）。 */
export function handleUserMessage(io: Server, user: AuthUser, message: ClientMessage): void {
  void dispatchAfterOwnerMessage(io, user, message, makeSink(io, user)).catch((error) => {
    console.warn(
      `[ai] 消息回复调度失败 message=${message.id}:`,
      error instanceof Error ? error.message : error,
    );
  });
}
