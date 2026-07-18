import { describeAction, type ConfirmMeta } from "../actions/personalItems";
import { runAgentReply } from "./runtime";
import { PACE } from "../settings";
import { traceBegin, traceError, traceFlush, traceReply, traceTiming } from "../debug/trace";
import { startOperation } from "../../observability/operationLog";
import { errorCodeFor } from "../../errors/errorCodes";
import { updateConversationContext } from "../conversation/context";

export interface ReplySink {
  emit(storedChannel: string, text: string, isFirst: boolean, meta?: unknown): Promise<void>;
  typing(storedChannel: string, value: boolean): void;
  replying?(storedChannel: string, value: boolean): void;
  activity?(trigger: Trigger, phase: "accepted" | "generating" | "finished" | "failed"): void;
}

export interface Trigger {
  storedChannel: string;
  question: string;
  requesterName: string;
  requesterUsername: string;
  messageId?: string;
  currentImageUrl?: string;
  currentImageUrls?: string[];
  currentImageSenderName?: string;
  origin?: "user" | "conflict" | "interject";
  backgroundReason?: string;
  backgroundContext?: string;
}

export interface ResponseRunState {
  readonly cancelled: boolean;
  readonly signal: AbortSignal;
  emitted: boolean;
  /** 超时或正常路径谁先 claim 谁负责发用户可见文案，避免双发。 */
  claimEmit(): boolean;
  cancel(): void;
}

const FAILURE_REPLY = "我刚刚没接稳这句话，但我还在。你再发一次，我马上接住。";
const TIMEOUT_REPLY = "我这次想得有点久，先没接稳。你再喊我一下，我马上重新来。";

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function createRunState(): ResponseRunState {
  let claimed = false;
  const controller = new AbortController();
  return {
    get cancelled() {
      return controller.signal.aborted;
    },
    signal: controller.signal,
    emitted: false,
    claimEmit() {
      if (claimed) return false;
      claimed = true;
      return true;
    },
    cancel() {
      controller.abort();
    },
  };
}

async function respond(trigger: Trigger, sink: ReplySink, state: ResponseRunState): Promise<void> {
  let failed = false;
  const background = trigger.origin === "conflict" || trigger.origin === "interject";
  if (!background) sink.activity?.(trigger, "generating");
  sink.typing(trigger.storedChannel, true);
  sink.replying?.(trigger.storedChannel, true);
  const trace = traceBegin(trigger.storedChannel, trigger.requesterName, trigger.question, trigger.messageId);
  try {
    const startedAt = Date.now();
    const result = await runAgentReply(trigger, trace, state.signal);
    traceTiming(trace, "agent", startedAt);
    if (!result) throw new Error("Agent 没有生成有效结果");
    if (!result.replies.length) {
      if (background) {
        traceReply(trace, {
          stage: "Agent + MCP（选择沉默）",
          usedVision: result.usedVision,
          wantsSearch: result.citations.length > 0,
          replies: [],
          actions: [],
          rawOutput: result.rawOutput,
        });
        return;
      }
      throw new Error("Agent 没有生成有效回复");
    }

    const actions = result.actions.filter((action) => describeAction(action));
    const confirmMeta: ConfirmMeta | null = actions.length
      ? {
          confirm: {
            status: "pending",
            items: actions.map((action) => ({ action, label: describeAction(action)! })),
            requesterName: trigger.requesterName,
            requesterUsername: trigger.requesterUsername,
          },
        }
      : null;
    const searchMeta = result.citations.length
      ? { search: { items: result.citations, ts: Date.now() } }
      : null;
    const lastMeta: Record<string, unknown> = {};
    if (confirmMeta) Object.assign(lastMeta, confirmMeta);
    if (searchMeta) Object.assign(lastMeta, searchMeta);

    traceReply(trace, {
      stage: "Agent + MCP",
      usedVision: result.usedVision,
      wantsSearch: result.citations.length > 0,
      replies: result.replies,
      actions,
      rawOutput: result.rawOutput,
    });

    const emitStartedAt = Date.now();
    for (let index = 0; index < result.replies.length; index += 1) {
      if (state.cancelled) break;
      if (index === 0 && !state.claimEmit()) break;
      if (index > 0) await sleep(PACE.replyGapMinMs + Math.floor(Math.random() * PACE.replyGapJitterMs));
      if (state.cancelled) break;
      const isLast = index === result.replies.length - 1;
      await sink.emit(
        trigger.storedChannel,
        result.replies[index],
        index === 0,
        isLast && Object.keys(lastMeta).length ? lastMeta : null,
      );
      state.emitted = true;
    }
    traceTiming(trace, "emit", emitStartedAt);
    if (!state.cancelled) {
      void updateConversationContext(trigger.storedChannel, trigger.messageId).catch(() => undefined);
    }
  } catch (error) {
    failed = true;
    if (!background) sink.activity?.(trigger, "failed");
    const message = error instanceof Error ? error.message : String(error);
    traceError(trace, message);
    console.warn("[ai] Agent 应答失败:", message);
    if (!background && !state.cancelled && !state.emitted && state.claimEmit()) {
      await sink.emit(trigger.storedChannel, FAILURE_REPLY, true);
      state.emitted = true;
      traceReply(trace, {
        stage: "异常兜底",
        usedVision: false,
        wantsSearch: false,
        replies: [FAILURE_REPLY],
        actions: [],
      });
    }
  } finally {
    sink.typing(trigger.storedChannel, false);
    sink.replying?.(trigger.storedChannel, false);
    if (!background && !failed && !state.cancelled) sink.activity?.(trigger, "finished");
    traceFlush(trace);
  }
}

export type ReplyTask = (state: ResponseRunState) => Promise<void>;

export async function runReplyTaskWithTimeout(
  trigger: Trigger,
  sink: ReplySink,
  task: ReplyTask,
  timeoutMs: number = PACE.respondTimeoutMs,
): Promise<void> {
  const state = createRunState();
  const operation = startOperation("ai.reply", {
    requestId: trigger.messageId ?? "background",
    channel: trigger.storedChannel,
    origin: trigger.origin ?? "user",
  });
  const background = trigger.origin === "conflict" || trigger.origin === "interject";
  let timer: NodeJS.Timeout | null = null;
  let timedOut = false;
  let failure: unknown;
  const timeout = new Promise<void>((resolve) => {
    timer = setTimeout(() => {
      void (async () => {
        state.cancel();
        timedOut = true;
        console.warn(`[ai] 应答超时，已释放频道队列: ${trigger.storedChannel}`);
        if (!background && !state.emitted && state.claimEmit()) {
          await sink.emit(trigger.storedChannel, TIMEOUT_REPLY, true).catch(() => undefined);
          state.emitted = true;
        }
        sink.typing(trigger.storedChannel, false);
        sink.replying?.(trigger.storedChannel, false);
        if (!background) sink.activity?.(trigger, "failed");
        resolve();
      })();
    }, timeoutMs);
  });
  try {
    await Promise.race([task(state), timeout]);
  } catch (error) {
    failure = error;
    throw error;
  } finally {
    if (timer) clearTimeout(timer);
    if (timedOut) operation.timeout({ emitted: state.emitted });
    else if (failure) operation.failure(errorCodeFor(failure), { emitted: state.emitted });
    else operation.success({ emitted: state.emitted });
  }
}

interface QueueItem {
  trigger: Trigger;
  sink: ReplySink;
}

interface Queue {
  chain: Promise<void>;
  pending: number;
  deferred: QueueItem | null;
}

export type QueueResult = "queued" | "coalesced";
export type ReplyRunner = (trigger: Trigger, sink: ReplySink) => Promise<void>;

export class ReplyQueue {
  private readonly queues = new Map<string, Queue>();

  constructor(
    private readonly runner: ReplyRunner = (trigger, sink) =>
      runReplyTaskWithTimeout(trigger, sink, (state) => respond(trigger, sink, state)),
    private readonly maxPending: number = PACE.queuePendingMax,
  ) {}

  enqueue(trigger: Trigger, sink: ReplySink): QueueResult {
    const queue = this.queues.get(trigger.storedChannel) ?? {
      chain: Promise.resolve(),
      pending: 0,
      deferred: null,
    };
    this.queues.set(trigger.storedChannel, queue);
    const item = { trigger, sink };
    if (queue.deferred || queue.pending >= this.maxPending) {
      const dropped = queue.deferred;
      queue.deferred = item;
      if (dropped) {
        // 被合并掉的请求需要关闭 activity，避免客户端一直 generating。
        const background = dropped.trigger.origin === "conflict" || dropped.trigger.origin === "interject";
        if (!background) dropped.sink.activity?.(dropped.trigger, "failed");
      }
      console.warn(`[ai] 频道队列繁忙，已合并为最新请求: ${trigger.storedChannel}`);
      return "coalesced";
    }
    this.schedule(queue, item);
    return "queued";
  }

  private schedule(queue: Queue, item: QueueItem): void {
    queue.pending += 1;
    queue.chain = queue.chain
      .then(() => this.runner(item.trigger, item.sink))
      .catch((error) => console.warn("[ai] 应答失败:", error instanceof Error ? error.message : error))
      .finally(() => {
        queue.pending -= 1;
        if (queue.pending === 0 && queue.deferred) {
          const latest = queue.deferred;
          queue.deferred = null;
          this.schedule(queue, latest);
        } else if (queue.pending === 0) {
          this.queues.delete(item.trigger.storedChannel);
        }
      });
  }
}

const replyQueue = new ReplyQueue();

export function queueRespond(trigger: Trigger, sink: ReplySink): QueueResult {
  return replyQueue.enqueue(trigger, sink);
}
