// 应答引擎：一轮 LLM 调用直出 1~3 条回复，像真人发微信一样逐条发出。
//
// 上下文分两层组织（这是缓存友好的关键设计）：
//   system  = 人设 + 人物卡 + 关系卡 + 短期记忆 + 今日心情 + 输出格式
//             ——一天内基本不变，Claude 系模型能吃到提示词缓存（约 1/10 计费）。
//   user    = 对话前情摘要 + 最近聊天 + 静默召回的记忆 + 当前这条消息
//             ——每次都变的部分。
//
// 对比旧版：意图判断和独立检索词生成并行，再进行正式回复；
// 既保留高质量的指代消解/记忆检索，又不增加两者之间的串行等待。

import { accounts, getDoc } from "./memoryStore";
import { compactLine, latestImage, recentMessages, type LogMessage } from "./chatLog";
import { chat, describeImage, extractJson, extractReplyText, webSearch, type SearchResult, type Citation } from "./provider";
import { recallSafe, type Recalled } from "./recall";
import { summaryText } from "./sessionSummary";
import { ensureDailyMood } from "./nightly";
import { personaCore, BOT_NAME } from "./persona";
import { classifyIntent, generateRetrievalQuery, type PlanContext } from "./intent";
import { tasksContext, tasksTextRich } from "./tasksContext";
import { describeAction, parseActions, type AiAction, type ConfirmMeta } from "./actionService";
import { CONTEXT, GEN, MEMORY, PACE } from "./params";
import { beijingDateTime, cycleDate } from "./time";
import {
  traceBegin,
  traceIntent,
  traceRetrievalPlan,
  traceRetrieval,
  traceContext,
  traceReply,
  traceError,
  traceFlush,
  type TraceEntry,
} from "./trace";

const NO_RECALL: Recalled = { factsContext: "", episodesContext: "" };

export interface ReplySink {
  // 发一条大橘消息进频道（含入库+广播+推送），返回后继续下一条。
  // meta 仅传给最后一条（actions 确认卡 / 搜索来源卡片）。
  emit(storedChannel: string, text: string, isFirst: boolean, meta?: unknown): Promise<void>;
  // 「正在输入」气泡开关。
  typing(storedChannel: string, value: boolean): void;
  // 「正在回复」开始时通知客户端，便于更稳地显示回复中的状态。
  replying?(storedChannel: string, value: boolean): void;
}

export interface Trigger {
  storedChannel: string;
  question: string;
  requesterName: string;
  requesterUsername: string;
  messageId?: string;
  currentImageUrl?: string;
  currentImageSenderName?: string;
}

export interface ResponseRunState {
  cancelled: boolean;
  emitted: boolean;
}

const FAILURE_REPLY = "我刚刚没接稳这句话，但我还在。你再发一次，我马上接住。";
const TIMEOUT_REPLY = "我这次想得有点久，先没接稳。你再喊我一下，我马上重新来。";

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ─── 上下文组装 ──────────────────────────────────────────────────────────

async function profileCardsText(): Promise<string> {
  const parts: string[] = [];
  for (const a of accounts()) {
    const text = await getDoc(`profile:${a.username}`);
    if (text) parts.push(`## ${a.name}\n${text}`);
  }
  const rel = await getDoc("relationship");
  if (rel) parts.push(`## 两人关系\n${rel}`);
  return parts.join("\n\n");
}

function actionInstructions(): string {
  return [
    "【可用 actions——这轮涉及提醒/备忘】",
    '- {"type":"add_reminder","title":"提醒内容","time":"YYYY-MM-DD HH:mm","ownerName":"主人昵称，可省略"}',
    '- {"type":"add_memo","text":"备忘录内容，可用 Markdown","ownerName":"主人昵称，可省略"}',
    '- {"type":"complete_reminder","id":"提醒 id"} 或用连续原文关键词填 text',
    '- {"type":"delete_reminder","id":"提醒 id"} 或用连续原文关键词填 text',
    '- {"type":"edit_memo","id":"备忘 id","newText":"修改后的完整内容"}；拿不到 id 时可用原备忘连续关键词填 text',
    "带明确提醒时间的请求用 add_reminder；只想保存内容、清单或笔记且没有提醒时间时用 add_memo；修改已有备忘用 edit_memo。一次提多件事就生成多个 actions。",
    'add_reminder.time 必须根据【现在】换算成完整北京时间 "YYYY-MM-DD HH:mm"；「待会儿/过会儿」默认 30 分钟后。绝不能保留相对时间，也不能只写时分。',
    "完成、删除、修改已有项目时优先使用【提醒/备忘概况】里的 id；没有 id 才用原文中连续出现的关键词，不要自行改写。",
    "add_memo.text 可使用 Markdown，复杂内容才使用标题/列表；不要为了排版而排版。",
    "actions 会先展示确认卡，主人确认后才执行。因此回复要说『要我帮你设在…吗』『我整理好了，确认一下』，不能说已经完成。",
  ].join("\n");
}

function buildSystem(isPrivate: boolean, mood: string, plan: PlanContext, cards: string, shortTerm: string): string {
  const names = accounts().map((a) => a.name);
  return [
    personaCore(names),
    isPrivate
      ? "这里是你和其中一位主人的私聊小窗：只有你们两个，说话可以更贴近这一位主人；私聊内容不要透给另一位主人。"
      : "这里是两位主人共同的聊天频道，他们 @你 时你才说话；你说的话两个人都看得到。",
    cards ? `【你对两位主人的了解（人物卡）】\n${cards}` : "",
    shortTerm ? `【短期记忆（最近一周发生的事）】\n${shortTerm}` : "",
    mood ? `【你今天的心情底色】${mood}` : "",
    plan.needClarification
      ? "这句话有点模糊，答不准的话可以先反问澄清一下，不用勉强给出猜测的答案。"
      : "",
    "【记忆怎么用——这是你像「活的」的关键】",
    "下面可能出现的【相关记忆】是你自己记得的事，不是数据库查询结果；想提的时候要像人突然想起来一样自然（「诶我记得你上次说…」「你不是不吃香菜吗」），一次最多自然带出一件；跟当前话题无关的就当没想起来，绝不罗列，绝不说「根据我的记录/记忆文档显示」这种机器话。",
    "【不要给记忆加戏】记忆条目只是精炼过的一句话事实，不带来龙去脉；你只能说条目本身写到的内容，绝不能自己脑补是谁说的、什么时候说、当时什么情景这类原文没给的细节——编造听起来合理但没有依据的具体情节，比不提这件事更糟。",
    "【不确定就澄清，别猜】",
    "如果当前请求里的「那个/这个/刚刚/刚才/前面/他/她/它/你觉得呢」在【紧邻上文】和【更早背景】里都找不到明确指代，先用一句很短的话问清楚，不要自作主张补全；当前请求优先级最高，各类记忆只做辅助，不能覆盖主人当前明确说的话。",
    "【上下文证据优先级】当前请求 > 紧邻上文 > 明确命中的过往事件/长期事实 > 前情摘要 > 人物卡、关系卡和心情底色。发生冲突时永远采用更靠前、更新的证据。人物卡只是帮助理解的背景，不是心理诊断；除非主人主动要求分析，否则不要给人贴标签、推断深层动机或把普通聊天过度解读成关系问题。",
    "",
    "【回复格式——像人发微信一样说话】",
    "一次 1~3 条短消息，像真人打字一样逐条发出。日常闲聊 1 条、甚至半句话就够了；有转折或两层意思时拆成 2 条。第一条就要接住问题或情绪，必须有实际信息；不要单独发「让我想想」「来了来了」之类占位话。日常闲聊 1~2 句是常态，不要为了凑数硬拆，也不要每次长篇大论。",
    "不要用「亲爱的用户」式客服腔。",
    plan.needTasks ? actionInstructions() : "",
    "",
    '只输出 JSON：{"replies":["第一条","第二条（可选）","第三条（可选）"],"actions":[]}',
    "不要输出 JSON 以外的任何内容。不需要 action 时 actions 留空数组。",
  ].filter(Boolean).join("\n\n");
}

function buildUser(
  trigger: Trigger,
  recent: LogMessage[],
  factsContext: string,
  episodesContext: string,
  imageContext: string,
  tasksText: string,
  searchContext: string,
  plan: PlanContext,
  summary: string,
): string {
  const lines = recent
    .filter((m) => m.kind !== "system")
    .map((m) => compactLine(m))
    .filter(Boolean);
  const n = CONTEXT.immediateCount;
  const earlier = lines.slice(0, Math.max(0, lines.length - n)).join("\n");
  const immediate = lines.slice(-n).join("\n") || "暂无最近聊天";
  return [
    `现在是 ${beijingDateTime(Date.now())}（北京时间）。`,
    summary ? `【前情摘要（更早对话的脉络）】\n${summary}` : "",
    earlier ? `【更早背景】\n${earlier}` : "",
    `【紧邻上文（重点看这里）】\n${immediate}`,
    factsContext ? `【相关记忆（长期事实）】\n${factsContext}` : "",
    episodesContext ? `【相关记忆（过往事件）】\n${episodesContext}` : "",
    imageContext ? `【你刚看了一眼最近的图片】\n${imageContext}` : "",
    tasksText ? `【提醒/备忘概况】\n${tasksText}` : "",
    searchContext ? `【联网查到的信息】\n${searchContext}` : "",
    plan.needSearch && !searchContext
      ? "（这个问题看起来需要联网查最新信息，但这次没查到，如实告诉对方查不到，不要编造内容。）"
      : "",
    `${trigger.requesterName} 对你说：${trigger.question || "（没有正文，可能只是唤了你一声）"}`,
    `请以${BOT_NAME}的身份回复。`,
  ].filter(Boolean).join("\n\n");
}

// 检索查询词：当前问题 + 最近几条用户消息原文拼接。
function retrievalQuery(trigger: Trigger, recent: LogMessage[]): string {
  const recentUser = recent
    .filter((m) => m.kind === "user" && m.type === "text" && m.text.trim())
    .slice(-CONTEXT.retrievalRecentUserLines)
    .map((m) => m.text.slice(0, 80));
  return [trigger.question, ...recentUser].join(" ").slice(0, 400);
}

function normalizeReplies(out: string | null): string[] {
  const parsed = extractJson<{ replies?: unknown; reply?: unknown }>(out);
  if (parsed && Array.isArray(parsed.replies)) {
    const replies = parsed.replies.map((r) => String(r ?? "").trim()).filter(Boolean).slice(0, 3);
    if (replies.length) return replies;
  }
  if (parsed && typeof parsed.reply === "string" && parsed.reply.trim()) {
    return [parsed.reply.trim()];
  }
  const fallback = extractReplyText(out);
  return fallback ? [fallback.trim()] : [];
}

// ─── 应答 ────────────────────────────────────────────────────────────────

async function respond(trigger: Trigger, sink: ReplySink, state: ResponseRunState): Promise<void> {
  const isPrivate = trigger.storedChannel.startsWith("ai:");
  sink.typing(trigger.storedChannel, true);
  sink.replying?.(trigger.storedChannel, true);
  const trace = traceBegin(trigger.storedChannel, trigger.requesterName, trigger.question);
  try {
    const recentWithCurrent = await recentMessages(trigger.storedChannel, CONTEXT.recentCount);
    // 当前消息会在触发 AI 前先入库；从上下文中排除，避免同一句既出现在最近聊天、又作为当前请求重复两次。
    const recent = trigger.messageId
      ? recentWithCurrent.filter((message) => message.id !== trigger.messageId)
      : recentWithCurrent;

    // M7：意图判断 + 独立检索词生成 并行跑（互不依赖，输入相同）。
    const [plan, retrievalPlan] = await Promise.all([
      classifyIntent(trigger.question, recent),
      generateRetrievalQuery(trigger.question, recent).catch(() => null),
    ]);
    if (trigger.currentImageUrl) plan.needImages = true;
    traceIntent(trace, plan);
    if (retrievalPlan) traceRetrievalPlan(trace, retrievalPlan);

    const effective: Trigger = { ...trigger, question: plan.resolvedQuestion || trigger.question };
    // 检索词优先级：独立检索词 > intent 自带 > 原文拼接兜底。
    const query =
      (retrievalPlan && retrievalPlan.retrievalQuery) ||
      plan.retrievalQuery ||
      retrievalQuery(effective, recent);

    const [recalled, mood, imageContext, searchResult, cards, shortTerm, summary] = await Promise.all([
      plan.needMemory || plan.needRetrieval
        ? recallSafe(query, trigger.storedChannel)
        : Promise.resolve(NO_RECALL),
      ensureDailyMood().catch(() => ""),
      describeLatestImageIfNeeded(plan, recentWithCurrent, trigger),
      plan.needSearch ? webSearch(query, GEN.search) : Promise.resolve<SearchResult | null>(null),
      plan.needMemory ? profileCardsText().catch(() => "") : Promise.resolve(""),
      plan.needShortMemory ? getDoc("short-term").then((t) => t.slice(0, MEMORY.shortTermMax)).catch(() => "") : Promise.resolve(""),
      summaryText(trigger.storedChannel).catch(() => ""),
    ]);
    const tasksText = plan.needTasks ? await tasksTextRich().catch(() => "") : "";
    const search = searchResult?.content ?? "";

    // 排查 trace：检索原始得分 + 过阈值情况。
    traceRetrieval(trace, {
      query,
      factMinScore: MEMORY.factMinScore,
      episodeMinScore: MEMORY.episodeMinScore,
      rawFacts: [],
      rawEpisodes: [],
    });
    traceContext(trace, {
      profileCards: cards,
      mood,
      shortMemory: shortTerm,
      factsContext: recalled.factsContext,
      episodesContext: recalled.episodesContext,
      imageContext,
      searchContext: search,
      tasksText,
      sessionSummary: summary,
      recentEarlier: "",
      recentImmediate: "",
    });

    console.log(
      `[ai] intent=${plan.intent} 记忆=${plan.needMemory} 检索=${plan.needRetrieval} 看图=${plan.needImages}` +
        `${imageContext ? "(命中)" : ""} 联网=${plan.needSearch}${search ? "(命中)" : ""} 任务=${plan.needTasks}` +
        (retrievalPlan ? ` 检索词="${retrievalPlan.retrievalQuery.slice(0, 40)}"` : ""),
    );

    const systemText = buildSystem(isPrivate, mood, plan, cards, shortTerm);
    const userText = buildUser(effective, recent, recalled.factsContext, recalled.episodesContext, imageContext, tasksText, search, plan, summary);
    let out = await chat({
      profile: "chat",
      system: systemText,
      user: userText,
      gen: GEN.reply,
    });
    let replies = normalizeReplies(out);
    if (!replies.length) {
      // 上游瞬时抖动（超时/限流）先原样重试一次；仍失败发固定兜底，绝不已读不回。
      out = await chat({
        profile: "chat",
        system: systemText,
        user: userText,
        gen: GEN.reply,
      });
      replies = normalizeReplies(out);
    }
    if (!replies.length) {
      replies = ["呜…我刚脑子卡了一下喵，没接住这句。再说一次好不好？"];
    }

    // 解析 AI 输出的 actions：建提醒/备忘等。打包成确认卡挂在最后一条回复上。
    const actions = parseActions(out);
    const validActions = actions.filter((a) => describeAction(a));
    const confirmMeta: ConfirmMeta | null = validActions.length
      ? {
          confirm: {
            status: "pending",
            items: validActions.map((a) => ({ action: a, label: describeAction(a)! })),
            requesterName: trigger.requesterName,
            requesterUsername: trigger.requesterUsername,
          },
        }
      : null;

    // 联网搜索的来源卡片（如果有）：单独挂在最后一条消息，跟确认卡合并（极少同框）。
    const searchMeta = searchResult && searchResult.annotations.length
      ? { search: { items: searchResult.annotations, ts: Date.now() } }
      : null;

    // 合并 confirmMeta 和 searchMeta 到同一个 meta 对象。
    const lastMeta: Record<string, unknown> = {};
    if (confirmMeta) Object.assign(lastMeta, confirmMeta);
    if (searchMeta) Object.assign(lastMeta, searchMeta);
    const finalLastMeta = Object.keys(lastMeta).length ? lastMeta : null;

    traceReply(trace, {
      stage: plan.needSearch ? "联网搜索后作答" : "直接回答",
      usedVision: Boolean(imageContext),
      wantsSearch: plan.needSearch,
      replies,
      actions: validActions,
    });

    for (let i = 0; i < replies.length; i += 1) {
      if (state.cancelled) break;
      if (i > 0) await sleep(PACE.replyGapMinMs + Math.floor(Math.random() * PACE.replyGapJitterMs));
      if (state.cancelled) break;
      const isLast = i === replies.length - 1;
      await sink.emit(trigger.storedChannel, replies[i], i === 0, isLast ? finalLastMeta : null);
      state.emitted = true;
    }

    if (validActions.length) {
      console.log(`[ai] 待确认 actions: ${validActions.map((a) => a.type).join(", ")}`);
    }
    if (searchResult && searchResult.annotations.length) {
      console.log(`[ai] 联网搜索返回 ${searchResult.annotations.length} 条来源`);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    traceError(trace, message);
    console.warn("[ai] respond 失败:", message);
    if (!state.cancelled && !state.emitted) {
      try {
        await sink.emit(trigger.storedChannel, FAILURE_REPLY, true);
        state.emitted = true;
        traceReply(trace, {
          stage: "异常兜底",
          usedVision: false,
          wantsSearch: false,
          replies: [FAILURE_REPLY],
          actions: [],
        });
      } catch (fallbackError) {
        console.warn("[ai] 异常兜底发送失败:", fallbackError instanceof Error ? fallbackError.message : fallbackError);
      }
    }
  } finally {
    sink.typing(trigger.storedChannel, false);
    sink.replying?.(trigger.storedChannel, false);
    traceFlush(trace);
  }
}

// needImages 命中时才去找最近一张图片识图；没有相关图片或识图失败就返回空串（正常聊，不提图片）。
async function describeLatestImageIfNeeded(
  plan: PlanContext,
  recent: LogMessage[],
  trigger: Trigger,
): Promise<string> {
  if (!plan.needImages) return "";
  if (trigger.currentImageUrl) {
    const description = await describeImage(trigger.currentImageUrl, GEN.describeImage);
    return description
      ? `${trigger.currentImageSenderName || trigger.requesterName}刚发的图片，内容大致是：${description}`
      : "";
  }
  const image = latestImage(recent);
  if (!image?.url) return "";
  const description = await describeImage(image.url, GEN.describeImage);
  return description ? `${image.senderName}发的图片，内容大致是：${description}` : "";
}

// ─── 每频道串行队列 ──────────────────────────────────────────────────────
// 连环 @ 时不并发（并发容易触发上游限流），串行逐条回答；
// 积压超过上限时合并为最新触发，待当前队列排空后继续回答。

export type ReplyTask = (state: ResponseRunState) => Promise<void>;

/// 超时不仅释放队列，还会发一条明确反馈，并阻止已超时的旧任务稍后乱序写回。
export async function runReplyTaskWithTimeout(
  trigger: Trigger,
  sink: ReplySink,
  task: ReplyTask,
  timeoutMs: number = PACE.respondTimeoutMs,
): Promise<void> {
  const state: ResponseRunState = { cancelled: false, emitted: false };
  let timer: NodeJS.Timeout | null = null;
  const timeout = new Promise<void>((resolve) => {
    timer = setTimeout(() => {
      void (async () => {
        state.cancelled = true;
        console.warn(`[ai] 应答超时，已发送兜底并释放频道队列: ${trigger.storedChannel}`);
        if (!state.emitted) {
          try {
            await sink.emit(trigger.storedChannel, TIMEOUT_REPLY, true);
            state.emitted = true;
          } catch (error) {
            console.warn("[ai] 超时兜底发送失败:", error instanceof Error ? error.message : error);
          }
        }
        sink.typing(trigger.storedChannel, false);
        sink.replying?.(trigger.storedChannel, false);
        resolve();
      })();
    }, timeoutMs);
  });
  try {
    await Promise.race([task(state), timeout]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function respondWithTimeout(trigger: Trigger, sink: ReplySink): Promise<void> {
  return runReplyTaskWithTimeout(trigger, sink, (state) => respond(trigger, sink, state));
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

/// 每频道串行；过载时保留最新一条，等现有队列排空后回答，绝不静默丢弃。
export class ReplyQueue {
  private readonly queues = new Map<string, Queue>();

  constructor(
    private readonly runner: ReplyRunner = respondWithTimeout,
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
      queue.deferred = item;
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
