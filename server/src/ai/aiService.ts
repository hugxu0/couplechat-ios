// AI 门面：realtime 层只跟这里打交道。
// 职责：入口分流（couple 召唤 / ai 私聊每条都答）、回复入库与广播、后台任务挂钩。

import type { Server } from "socket.io";
import type { AuthUser, ClientMessage } from "../types";
import { toStoredChannel, type StoredChannel } from "../types";
import { createAiMessage } from "../chat/messageService";
import { pushCoupleMessageToUnavailableRecipients } from "../push/pushService";
import { config } from "../config";
import { aiEnabled, describeImage } from "./provider";
import { GEN } from "./params";
import { loadAccounts } from "./memoryStore";
import { queueRespond, type ReplySink } from "./replyEngine";
import { onCoupleUserMessage } from "./extractor";
import { maybeUpdate as maybeUpdateSummary } from "./sessionSummary";
import { startScheduler } from "./nightly";

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
  return {
    async emit(storedChannel, text, isFirst) {
      const message = await createAiMessage(storedChannel as StoredChannel, text);
      if (storedChannel.startsWith("ai:")) {
        io.to(`user:${storedChannel.slice(3)}`).emit("message:new", message);
      } else {
        io.to("channel:couple").emit("message:new", message);
        // couple 里大橘的发言也推给不在线的一方（只推第一条，不轰炸）。
        if (isFirst) void pushCoupleMessageToUnavailableRecipients(message);
      }
    },
    typing(storedChannel, value) {
      // iOS 客户端把 ai:typing 当作 ai 私聊频道的输入指示（裸 bool），
      // couple 频道的回复不发 typing，避免错误点亮私聊气泡。
      if (storedChannel.startsWith("ai:")) {
        io.to(`user:${storedChannel.slice(3)}`).emit("ai:typing", value);
      }
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
    if (!aiEnabled()) return; // couple 频道未配置模型时不插话
    onCoupleUserMessage(); // 攒够 N 条触发一次事实提取
    if (isTriggered(message.text)) {
      queueRespond(
        { storedChannel, question: stripTrigger(message.text), requesterName: user.name },
        sink,
      );
    }
    return;
  }

  // ai 私聊：每条文本 / 图片都答，不需要召唤。
  if (!aiEnabled()) {
    void (async () => {
      sink.typing(storedChannel, true);
      await new Promise((resolve) => setTimeout(resolve, 550));
      await sink.emit(storedChannel, fallbackReply(isText ? message.text.trim() : ""), true);
      sink.typing(storedChannel, false);
    })().catch(() => {});
    return;
  }

  if (isText) {
    queueRespond(
      { storedChannel, question: message.text.trim(), requesterName: user.name },
      sink,
    );
    return;
  }

  // 图片：先识图拿一段简短描述，再把描述当问题喂给正常的回复流程（没配置识图/识图失败也不卡住，走兜底措辞）。
  void (async () => {
    const description = message.url ? await describeImage(message.url, GEN.describeImage) : null;
    const question = description
      ? `[用户发来一张图片，内容大致是：${description}]`
      : "[用户发来一张图片，你暂时看不清楚，自然地回应一下，不用提「看不清」这件事]";
    queueRespond({ storedChannel, question, requesterName: user.name }, sink);
  })().catch(() => {});
}
