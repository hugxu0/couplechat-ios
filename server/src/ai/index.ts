// AI 门面：realtime 层只跟这里打交道。
//
// 主人消息落库后 → dispatchAfterOwnerMessage（三线并行，见 pipeline.ts）
// 大橘回复入库与广播 → makeSink
// 后台冲突/搭话 → engagement 模块命中后经本文件排队 Agent

import type { Server } from "socket.io";
import { socketEvents } from "../contracts/realtime";
import type { AuthUser, ClientMessage } from "../types";
import { type StoredChannel } from "../types";
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
import { initializeMemory } from "./memory/extractor";
import { startMemoryMaintenance, stopMemoryMaintenance } from "./memory/maintenance";
import { subscribeMemoryDomainEvents } from "./memory/events";
import { setEngagementHandler, type EngagementSignal } from "./engagement";
import { dispatchAfterOwnerMessage } from "./pipeline";
import { scheduleContextCatchUp } from "./conversation/context";

let activeIo: Server | null = null;
let pendingEngagement: EngagementSignal | null = null;
let stopMemoryEvents: (() => void) | null = null;

export async function initAi(): Promise<void> {
  stopMemoryEvents ??= subscribeMemoryDomainEvents();
  await loadAccounts();
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

export function shutdownAi(): void {
  stopMemoryMaintenance();
  stopMemoryEvents?.();
  stopMemoryEvents = null;
  setEngagementHandler(null);
  activeIo = null;
  pendingEngagement = null;
}

function makeSink(io: Server, user?: AuthUser): ReplySink {
  const accountRoom = `account:${user?.accountId ?? user?.username ?? "unknown"}`;
  const coupleRoom = `couple:${user?.coupleId ?? "cpl_legacy_xusi"}`;
  const activityRoom = (storedChannel: string) => (storedChannel.startsWith("ai:")
    ? accountRoom
    : coupleRoom);
  return {
    async emit(storedChannel, text, isFirst, meta) {
      const message = await createAiMessage(storedChannel as StoredChannel, text, meta, user);
      // 大橘发言也推进日上下文，便于后续总览含「大橘说过什么」。
      scheduleContextCatchUp(storedChannel);
      if (storedChannel.startsWith("ai:")) {
        io.to(accountRoom).emit(socketEvents.messageNew, message);
        if (isFirst) void pushPrivateAiMessageToUnavailableRecipient(message, user?.username);
      } else {
        io.to(coupleRoom).emit(socketEvents.messageNew, message);
        if (isFirst) {
          void pushCoupleMessageToUnavailableRecipients(
            message,
            user?.coupleId ?? "cpl_legacy_xusi",
          );
        }
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
  if (pendingEngagement) {
    const signal = pendingEngagement;
    pendingEngagement = null;
    submitEngagementReply(io, signal);
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
    `[ai] engagement→Agent kind=${signal.kind} conf=${signal.confidence.toFixed(2)} topic=${signal.topicHint || "—"} queue=${result}`,
  );
}

/** 真人消息已写入后的 AI 入口（不阻塞 message.send）。 */
export function handleUserMessage(io: Server, user: AuthUser, message: ClientMessage): void {
  dispatchAfterOwnerMessage(io, user, message, makeSink(io, user));
}
