import { describeAction, type ConfirmMeta } from "../actions/personalItems";
import { runAgentReply } from "./runtime";
import { PACE } from "../settings";
import { traceBegin, traceError, traceFlush, traceReply, traceTiming } from "../debug/trace";
import { startOperation } from "../../observability/operationLog";
import { errorCodeFor } from "../../errors/errorCodes";
import { updateConversationContext } from "../conversation/context";
import { domainEvents } from "../../events/domainEvents";
import {
  claimAiReplyJob,
  markAiReplyJobCancelled,
  markAiReplyJobFailed,
  markAiReplyJobIgnored,
} from "./replyJobs";

export interface ReplySink {
  emit(
    storedChannel: string,
    text: string,
    isFirst: boolean,
    meta?: unknown,
    triggerMessageId?: string,
  ): Promise<void>;
  emitBatch?(
    storedChannel: string,
    parts: Array<{ text: string; meta?: unknown }>,
    triggerMessageId?: string,
  ): Promise<void>;
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
  readonly failure: unknown | null;
  readonly recoveredFromMaxTurns: boolean;
  emitted: boolean;
  /** 超时或正常路径谁先 claim 谁负责发用户可见文案，避免双发。 */
  claimEmit(): boolean;
  /** respond 会吞掉内部异常以发送兜底；在这里保留真实终态供操作日志判定。 */
  markFailure(error: unknown): void;
  markRecoveredFromMaxTurns(): void;
  cancel(): void;
}

const FAILURE_REPLY = "我刚刚没接稳这句话，但我还在。你再发一次，我马上接住。";
const TIMEOUT_REPLY = "我这次想得有点久，先没接稳。你再喊我一下，我马上重新来。";

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function createRunState(): ResponseRunState {
  let claimed = false;
  let failure: unknown | null = null;
  let recoveredFromMaxTurns = false;
  const controller = new AbortController();
  return {
    get cancelled() {
      return controller.signal.aborted;
    },
    get failure() {
      return failure;
    },
    get recoveredFromMaxTurns() {
      return recoveredFromMaxTurns;
    },
    signal: controller.signal,
    emitted: false,
    claimEmit() {
      if (claimed) return false;
      claimed = true;
      return true;
    },
    markFailure(error) {
      failure ??= error;
    },
    markRecoveredFromMaxTurns() {
      recoveredFromMaxTurns = true;
    },
    cancel() {
      controller.abort();
    },
  };
}

function isBackgroundTrigger(trigger: Trigger): boolean {
  return trigger.origin === "conflict" || trigger.origin === "interject";
}

function cancellationError(): Error {
  return new Error("ai_reply_cancelled");
}

async function emitWithDeadline(
  sink: ReplySink,
  trigger: Trigger,
  state: ResponseRunState,
  timeoutMs: number,
): Promise<void> {
  let timer: NodeJS.Timeout | null = null;
  try {
    await Promise.race([
      sink.emit(trigger.storedChannel, TIMEOUT_REPLY, true, undefined, trigger.messageId),
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error("ai_timeout_reply_emit_timeout")), timeoutMs);
      }),
    ]);
    state.emitted = true;
  } catch (error) {
    state.markFailure(error);
    console.warn(
      "[ai] 超时兜底发送失败:",
      error instanceof Error ? error.message : error,
    );
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function respond(trigger: Trigger, sink: ReplySink, state: ResponseRunState): Promise<void> {
  let failed = false;
  const background = isBackgroundTrigger(trigger);
  if (!background) sink.activity?.(trigger, "generating");
  sink.typing(trigger.storedChannel, true);
  sink.replying?.(trigger.storedChannel, true);
  const trace = traceBegin(trigger.storedChannel, trigger.requesterName, trigger.question, trigger.messageId);
  try {
    const startedAt = Date.now();
    const result = await runAgentReply(trigger, trace, state.signal);
    traceTiming(trace, "agent", startedAt);
    if (!result) throw new Error("Agent 没有生成有效结果");
    if (result.recoveredFromMaxTurns) state.markRecoveredFromMaxTurns();
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
    const replyParts = result.replies.map((text, index) => ({
      text,
      meta: index === result.replies.length - 1 && Object.keys(lastMeta).length
        ? lastMeta
        : undefined,
    }));
    if (sink.emitBatch) {
      if (!state.cancelled && state.claimEmit()) {
        await sink.emitBatch(
          trigger.storedChannel,
          replyParts,
          trigger.messageId,
        );
        state.emitted = true;
      }
    } else {
      for (let index = 0; index < replyParts.length; index += 1) {
        if (state.cancelled) break;
        if (index === 0 && !state.claimEmit()) break;
        if (index > 0) await sleep(PACE.replyGapMinMs + Math.floor(Math.random() * PACE.replyGapJitterMs));
        if (state.cancelled) break;
        await sink.emit(
          trigger.storedChannel,
          replyParts[index].text,
          index === 0,
          replyParts[index].meta,
          index === 0 ? trigger.messageId : undefined,
        );
        state.emitted = true;
      }
    }
    traceTiming(trace, "emit", emitStartedAt);
    if (!state.cancelled) {
      void updateConversationContext(trigger.storedChannel, trigger.messageId).catch(() => undefined);
    }
  } catch (error) {
    failed = true;
    state.markFailure(error);
    if (!background) sink.activity?.(trigger, "failed");
    const message = error instanceof Error ? error.message : String(error);
    traceError(trace, message);
    console.warn("[ai] Agent 应答失败:", message);
    if (!background && !state.cancelled && !state.emitted && state.claimEmit()) {
      await sink.emit(trigger.storedChannel, FAILURE_REPLY, true, undefined, trigger.messageId);
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
  externalSignal?: AbortSignal,
  fallbackEmitTimeoutMs = 3_000,
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
  let externallyCancelled = false;
  let failure: unknown;
  let resolveCancellation: (() => void) | null = null;
  const cancellation = new Promise<void>((resolve) => {
    resolveCancellation = resolve;
  });
  const cancelFromExternalSignal = () => {
    externallyCancelled = true;
    state.cancel();
    sink.typing(trigger.storedChannel, false);
    sink.replying?.(trigger.storedChannel, false);
    if (!background) sink.activity?.(trigger, "failed");
    resolveCancellation?.();
  };
  if (externalSignal) {
    if (externalSignal.aborted) {
      cancelFromExternalSignal();
    } else {
      externalSignal.addEventListener("abort", cancelFromExternalSignal, { once: true });
    }
  }
  const timeout = new Promise<void>((resolve) => {
    timer = setTimeout(() => {
      void (async () => {
        state.cancel();
        timedOut = true;
        console.warn(`[ai] 应答超时，已释放频道队列: ${trigger.storedChannel}`);
        if (!background && !state.emitted && state.claimEmit()) {
          await emitWithDeadline(
            sink,
            trigger,
            state,
            Math.max(1, fallbackEmitTimeoutMs),
          );
        }
        sink.typing(trigger.storedChannel, false);
        sink.replying?.(trigger.storedChannel, false);
        if (!background) sink.activity?.(trigger, "failed");
        resolve();
      })();
    }, timeoutMs);
  });
  const taskPromise = externalSignal?.aborted
    ? Promise.resolve()
    : Promise.resolve()
      .then(() => task(state))
      .catch((error) => {
        if (timedOut || externallyCancelled) return;
        throw error;
      });
  try {
    await Promise.race([taskPromise, timeout, cancellation]);
    // 定时器先触发时，底层任务通常会因 abort 更快结束。仍需等待有界的
    // timeout 分支完成，确保兜底写入已经成功或明确超时后再释放频道。
    if (timedOut) await timeout;
  } catch (error) {
    failure = error;
    throw error;
  } finally {
    if (timer) clearTimeout(timer);
    externalSignal?.removeEventListener("abort", cancelFromExternalSignal);
    const terminalFailure = failure ?? state.failure;
    if (timedOut) operation.timeout({ emitted: state.emitted });
    else if (externallyCancelled) {
      operation.failure(errorCodeFor(cancellationError()), {
        emitted: state.emitted,
        cancelled: true,
      });
    } else if (terminalFailure) {
      operation.failure(errorCodeFor(terminalFailure), {
        emitted: state.emitted,
        degraded: state.emitted,
        recoveredFromMaxTurns: state.recoveredFromMaxTurns,
      });
    } else {
      operation.success({
        emitted: state.emitted,
        recoveredFromMaxTurns: state.recoveredFromMaxTurns,
      });
    }
  }
}

interface QueueItem {
  trigger: Trigger;
  sink: ReplySink;
  controller: AbortController;
  cancellationNotified: boolean;
}

interface Queue {
  running: QueueItem | null;
  pending: QueueItem[];
  deferred: QueueItem | null;
}

export type QueueResult = "queued" | "coalesced" | "rejected";
export type ReplyRunner = (
  trigger: Trigger,
  sink: ReplySink,
  signal?: AbortSignal,
) => Promise<void>;

const defaultReplyRunner: ReplyRunner = async (trigger, sink, signal) => {
  // User-triggered replies are durable jobs. Background engagement has no
  // source message and therefore remains an in-memory task.
  if (!trigger.messageId) {
    return runReplyTaskWithTimeout(
      trigger,
      sink,
      (state) => respond(trigger, sink, state),
      PACE.respondTimeoutMs,
      signal,
    );
  }
  if (signal?.aborted) return;
  const claimed = await claimAiReplyJob(trigger.messageId);
  if (!claimed) return;
  try {
    await runReplyTaskWithTimeout(
      trigger,
      sink,
      (state) => respond(trigger, sink, state),
      PACE.respondTimeoutMs,
      signal,
    );
    // A successful run normally completes the job atomically with the first
    // reply insert. If no reply was persisted (for example a failed timeout
    // fallback), move it into the bounded retry state instead of leaving a
    // live lease forever.
    if (!signal?.aborted) {
      await markAiReplyJobFailed(trigger.messageId, "reply_completed_without_message")
        .catch(() => undefined);
    }
  } catch (error) {
    if (!signal?.aborted) {
      await markAiReplyJobFailed(
        trigger.messageId,
        error instanceof Error ? error.message : String(error),
      ).catch(() => undefined);
    }
    throw error;
  }
};

export class ReplyQueue {
  private readonly queues = new Map<string, Queue>();
  private readonly activeRuns = new Set<Promise<void>>();
  private readonly runnerPromises = new Set<Promise<void>>();
  private accepting = true;
  private readonly runner: ReplyRunner;

  constructor(
    runner?: ReplyRunner,
    private readonly maxPending: number = PACE.queuePendingMax,
  ) {
    this.runner = runner ?? defaultReplyRunner;
  }

  hasMessageId(messageId: string): boolean {
    if (!messageId) return false;
    for (const queue of this.queues.values()) {
      if (queue.running?.trigger.messageId === messageId) return true;
      if (queue.pending.some((item) => item.trigger.messageId === messageId)) return true;
      if (queue.deferred?.trigger.messageId === messageId) return true;
    }
    return false;
  }

  enqueue(trigger: Trigger, sink: ReplySink): QueueResult {
    if (trigger.messageId && this.hasMessageId(trigger.messageId)) return "queued";
    const item: QueueItem = {
      trigger,
      sink,
      controller: new AbortController(),
      cancellationNotified: false,
    };
    if (!this.accepting) {
      this.cancelItem(item);
      return "rejected";
    }
    const queue = this.queues.get(trigger.storedChannel) ?? {
      running: null,
      pending: [],
      deferred: null,
    };
    this.queues.set(trigger.storedChannel, queue);
    const queuedCount = (queue.running ? 1 : 0) + queue.pending.length;
    if (queue.deferred || queuedCount >= Math.max(1, this.maxPending)) {
      const dropped = queue.deferred;
      queue.deferred = item;
      if (dropped) this.cancelItem(dropped, "ignored");
      console.warn(`[ai] 频道队列繁忙，已合并为最新请求: ${trigger.storedChannel}`);
      return "coalesced";
    }
    queue.pending.push(item);
    this.pump(trigger.storedChannel, queue);
    return "queued";
  }

  start(): void {
    this.accepting = true;
  }

  cancelByMessageId(messageId: string): number {
    if (!messageId) return 0;
    let cancelled = 0;
    for (const [channel, queue] of this.queues) {
      if (queue.running?.trigger.messageId === messageId) {
        this.cancelItem(queue.running, "cancelled");
        cancelled += 1;
      }
      const retained: QueueItem[] = [];
      for (const item of queue.pending) {
        if (item.trigger.messageId === messageId) {
          this.cancelItem(item, "cancelled");
          cancelled += 1;
        } else {
          retained.push(item);
        }
      }
      queue.pending = retained;
      if (queue.deferred?.trigger.messageId === messageId) {
        this.cancelItem(queue.deferred, "cancelled");
        queue.deferred = null;
        cancelled += 1;
      }
      if (!queue.running) this.pump(channel, queue);
    }
    return cancelled;
  }

  async stop(timeoutMs = 5_000): Promise<boolean> {
    this.accepting = false;
    for (const queue of this.queues.values()) {
      // Shutdown cancellation is deliberately non-terminal for durable jobs:
      // the next process can claim pending/processing rows after a crash or
      // an intentionally short graceful-drain window.
      if (queue.running) this.cancelItem(queue.running, "preserve");
      for (const item of queue.pending) this.cancelItem(item, "preserve");
      queue.pending = [];
      if (queue.deferred) this.cancelItem(queue.deferred, "preserve");
      queue.deferred = null;
    }
    return this.waitForIdle(timeoutMs);
  }

  async waitForIdle(timeoutMs = 5_000): Promise<boolean> {
    const deadline = Date.now() + Math.max(0, timeoutMs);
    while (
      this.queues.size > 0
      || this.activeRuns.size > 0
      || this.runnerPromises.size > 0
    ) {
      if (Date.now() >= deadline) return false;
      const active = [...this.activeRuns, ...this.runnerPromises];
      await Promise.race([
        active.length ? Promise.allSettled(active).then(() => undefined) : Promise.resolve(),
        new Promise<void>((resolve) => setTimeout(resolve, 5)),
      ]);
    }
    return true;
  }

  private cancelItem(
    item: QueueItem,
    disposition: "cancelled" | "ignored" | "preserve" = "preserve",
  ): void {
    if (!item.controller.signal.aborted) item.controller.abort(cancellationError());
    if (item.cancellationNotified) return;
    item.cancellationNotified = true;
    item.sink.typing(item.trigger.storedChannel, false);
    item.sink.replying?.(item.trigger.storedChannel, false);
    if (!isBackgroundTrigger(item.trigger)) {
      item.sink.activity?.(item.trigger, "failed");
    }
    if (item.trigger.messageId && disposition !== "preserve") {
      const update = disposition === "cancelled"
        ? markAiReplyJobCancelled(item.trigger.messageId)
        : markAiReplyJobIgnored(item.trigger.messageId, "queue_coalesced");
      void update.catch(() => undefined);
    }
  }

  private guardedSink(item: QueueItem): ReplySink {
    const { signal } = item.controller;
    return {
      emit: async (...args) => {
        if (signal.aborted) throw cancellationError();
        await item.sink.emit(...args);
      },
      emitBatch: item.sink.emitBatch
        ? async (...args) => {
            if (signal.aborted) throw cancellationError();
            await item.sink.emitBatch!(...args);
          }
        : undefined,
      typing: (channel, value) => {
        if (!signal.aborted || !value) item.sink.typing(channel, value);
      },
      replying: (channel, value) => {
        if (!signal.aborted || !value) item.sink.replying?.(channel, value);
      },
      activity: (trigger, phase) => {
        if (!signal.aborted) item.sink.activity?.(trigger, phase);
      },
    };
  }

  private pump(channel: string, queue: Queue): void {
    if (queue.running) return;
    const item = queue.pending.shift() ?? queue.deferred;
    if (!item) {
      if (this.queues.get(channel) === queue) this.queues.delete(channel);
      return;
    }
    if (item === queue.deferred) queue.deferred = null;
    queue.running = item;

    const runnerPromise = Promise.resolve().then(() =>
      this.runner(item.trigger, this.guardedSink(item), item.controller.signal));
    this.runnerPromises.add(runnerPromise);
    void runnerPromise.then(
      () => this.runnerPromises.delete(runnerPromise),
      () => this.runnerPromises.delete(runnerPromise),
    );
    // Promise.race 已处理当前执行；额外 catch 防止取消后 runner 晚到的 rejection
    // 成为 unhandled rejection。
    void runnerPromise.catch(() => undefined);
    const cancellation = new Promise<void>((resolve) => {
      if (item.controller.signal.aborted) {
        resolve();
        return;
      }
      item.controller.signal.addEventListener("abort", () => resolve(), { once: true });
    });
    const active = Promise.race([runnerPromise, cancellation])
      .catch((error) => {
        if (!item.controller.signal.aborted) {
          console.warn("[ai] 应答失败:", error instanceof Error ? error.message : error);
        }
      })
      .finally(() => {
        this.activeRuns.delete(active);
        if (queue.running === item) queue.running = null;
        if (!queue.pending.length && queue.deferred) {
          queue.pending.push(queue.deferred);
          queue.deferred = null;
        }
        this.pump(channel, queue);
      });
    this.activeRuns.add(active);
  }
}

const replyQueue = new ReplyQueue();

export function queueRespond(trigger: Trigger, sink: ReplySink): QueueResult {
  return replyQueue.enqueue(trigger, sink);
}

export function cancelReplyForMessage(messageId: string): number {
  return replyQueue.cancelByMessageId(messageId);
}

export function hasQueuedReplyForMessage(messageId: string): boolean {
  return replyQueue.hasMessageId(messageId);
}

export function startReplyQueue(): void {
  replyQueue.start();
}

export function shutdownReplyQueue(timeoutMs = 5_000): Promise<boolean> {
  return replyQueue.stop(timeoutMs);
}

export function subscribeReplyDomainEvents(): () => void {
  return domainEvents.subscribe("message.recalled", ({ messageId }) => {
    replyQueue.cancelByMessageId(messageId);
  });
}
