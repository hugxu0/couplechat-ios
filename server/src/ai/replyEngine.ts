// 应答引擎：一轮 LLM 调用直出 1~3 条回复，像真人发微信一样逐条发出。
//
// 上下文分两层组织（这是缓存友好的关键设计）：
//   system  = 人设 + 人物卡 + 关系卡 + 短期记忆 + 今日心情 + 输出格式
//             ——一天内基本不变，Claude 系模型能吃到提示词缓存（约 1/10 计费）。
//   user    = 对话前情摘要 + 最近聊天 + 静默召回的记忆 + 当前这条消息
//             ——每次都变的部分。
//
// 对比旧版：plan（意图规划）+ retrievalQuery（检索词生成）+ ask（正式回复）三轮
// 合并成一轮；检索词直接用「当前问题 + 最近几条用户消息」拼接。

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
}

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
    "",
    "【回复格式——像人发微信一样说话】",
    "一次 1~3 条短消息，像真人打字一样逐条发出。日常闲聊 1 条、甚至半句话就够了；有转折/有两层意思时拆成 2 条（比如先反应情绪、再说正事）；别为了凑数硬拆，也别把一大段塞进一条。第一条往往是短反应（「哈？」「来了来了」「让我想想」这种），后面的条目展开说。日常闲聊 1~2 句是常态，不要每次都长篇大论。",
    "不要用「亲爱的用户」式客服腔。",
    "",
    "【可用 actions——你可以帮主人建提醒、记备忘、完成/删除已有提醒/备忘】",
    "- {\"type\":\"add_reminder\",\"title\":\"提醒内容\",\"time\":\"YYYY-MM-DD HH:mm\",\"ownerName\":\"主人昵称，可省略\"}",
    "- {\"type\":\"add_memo\",\"text\":\"备忘录内容，可用 Markdown\",\"ownerName\":\"主人昵称，可省略\"}",
    "- {\"type\":\"complete_reminder\",\"id\":\"提醒 id\"} 或 {\"type\":\"complete_reminder\",\"text\":\"提醒内容关键词\"}",
    "- {\"type\":\"delete_reminder\",\"id\":\"提醒 id\"} 或 {\"type\":\"delete_reminder\",\"text\":\"提醒内容关键词\"}",
    "- {\"type\":\"edit_memo\",\"id\":\"备忘 id\",\"newText\":\"修改后的完整内容\"} 或 {\"type\":\"edit_memo\",\"text\":\"原备忘关键词\",\"newText\":\"修改后的完整内容\"}",
    "",
    "【什么时候放 actions】",
    "1. 想在某个时间点被提醒做某事（「提醒我/叫我/别忘了/过会儿/等下/X分钟后/今晚/明天/几点几分」）→ add_reminder。宁可多建一条提醒，也不要把带时间的提醒错当成备忘。",
    "2. 想保存一段内容、清单、规划、笔记，没有具体提醒时间（「记到备忘/加个备忘/帮我写个备忘录」）→ add_memo。备忘是 Markdown 文档，不要给它生成「完成」动作。",
    "3. 想修改已有备忘（「改一下备忘/备忘里加一句」）→ edit_memo，newText 写修改后的完整内容，不要用 delete_memo + add_memo 两步凑。",
    "4. 主人一句话提了好几件事 → actions 放多个，每件事一个 action，replies 里自然把这几件事一起确认一下。",
    "5. 完成/删除某条提醒或备忘时，下面【当前未完成的提醒】【当前备忘录】里带了 id 就优先填 id 精确定位；只有确实拿不到 id 时才退回 text 关键词匹配，关键词要抄原文里一段连续出现的短语，不要改写、缩写或加标点。",
    "",
    "【add_reminder 的 time——非常重要】",
    "time 字段必须是绝对时间，格式严格为 \"YYYY-MM-DD HH:mm\"，要你自己根据【现在】时间把相对说法换算成绝对时间。",
    '换算示例（假设现在是 2026-06-23 14:00）：「一分钟后」→ 2026-06-23 14:01；「十分钟后」→ 2026-06-23 14:10；「过会儿/待会儿」→ 2026-06-23 14:30（默认30分钟）；「今晚8点」→ 2026-06-23 20:00；「明天9点」→ 2026-06-24 09:00；「下午3点半」→ 2026-06-23 15:30。',
    '绝对不要在 time 里写「过会儿」「一会儿」「晚点」这类相对词，也不要只写「20:00」而不带日期；一定换算成完整的 "YYYY-MM-DD HH:mm"。',
    "只要主人表达了「到点提醒我」的意思，就一定要生成 add_reminder，并在 replies 里自然确认你设在了几点。",
    "",
    "【add_memo 的规则】",
    "写备忘/总结/清单/规划时，text 用标准 Markdown 语法（标题、列表、加粗、表格等），每条开头自然带上日期（如 `## 2026-06-23 · 标题`）。内容简单就别硬塞排版。",
    "",
    "【重要——actions 不会立刻生效】",
    "你生成的提醒/备忘/记忆等 action 不会立刻写入，会先以一张「确认卡片」展示给主人，由主人点确认后才真正执行。",
    "所以 replies 里要用提议/征询的口吻，例如「要我帮你设个X点的提醒吗？」「这条我先记着，确认一下喵～」，不要说「已经加好了/已设好」，避免和卡片矛盾。",
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

async function respond(trigger: Trigger, sink: ReplySink): Promise<void> {
  const isPrivate = trigger.storedChannel.startsWith("ai:");
  sink.typing(trigger.storedChannel, true);
  sink.replying?.(trigger.storedChannel, true);
  const trace = traceBegin(trigger.storedChannel, trigger.requesterName, trigger.question);
  try {
    const recent = await recentMessages(trigger.storedChannel, CONTEXT.recentCount);

    // M7：意图判断 + 独立检索词生成 并行跑（互不依赖，输入相同）。
    const [plan, retrievalPlan] = await Promise.all([
      classifyIntent(trigger.question, recent),
      generateRetrievalQuery(trigger.question, recent).catch(() => null),
    ]);
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
      describeLatestImageIfNeeded(plan, recent),
      plan.needSearch ? webSearch(query, GEN.search) : Promise.resolve<SearchResult | null>(null),
      profileCardsText().catch(() => ""),
      plan.needShortMemory ? getDoc("short-term").then((t) => t.slice(0, MEMORY.shortTermMax)).catch(() => "") : Promise.resolve(""),
      summaryText(trigger.storedChannel).catch(() => ""),
    ]);
    const tasksText = plan.needTasks ? await tasksTextRich() : "";
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
      if (i > 0) await sleep(PACE.replyGapMinMs + Math.floor(Math.random() * PACE.replyGapJitterMs));
      const isLast = i === replies.length - 1;
      await sink.emit(trigger.storedChannel, replies[i], i === 0, isLast ? finalLastMeta : null);
    }

    if (validActions.length) {
      console.log(`[ai] 待确认 actions: ${validActions.map((a) => a.type).join(", ")}`);
    }
    if (searchResult && searchResult.annotations.length) {
      console.log(`[ai] 联网搜索返回 ${searchResult.annotations.length} 条来源`);
    }
  } catch (error) {
    traceError(trace, error instanceof Error ? error.message : String(error));
    console.warn("[ai] respond 失败:", error instanceof Error ? error.message : error);
  } finally {
    sink.typing(trigger.storedChannel, false);
    sink.replying?.(trigger.storedChannel, false);
    traceFlush(trace);
  }
}

// needImages 命中时才去找最近一张图片识图；没有相关图片或识图失败就返回空串（正常聊，不提图片）。
async function describeLatestImageIfNeeded(plan: PlanContext, recent: LogMessage[]): Promise<string> {
  if (!plan.needImages) return "";
  const image = latestImage(recent);
  if (!image?.url) return "";
  const description = await describeImage(image.url, GEN.describeImage);
  return description ? `${image.senderName}发的图片，内容大致是：${description}` : "";
}

// ─── 每频道串行队列 ──────────────────────────────────────────────────────
// 连环 @ 时不并发（并发容易触发上游限流），串行逐条回答；
// 积压超过上限直接丢弃新触发（兜底回复已经给了反馈，不用轰炸）。

interface Queue {
  chain: Promise<void>;
  pending: number;
}

const queues = new Map<string, Queue>();

function respondWithTimeout(trigger: Trigger, sink: ReplySink): Promise<void> {
  let timer: NodeJS.Timeout | null = null;
  return Promise.race([
    respond(trigger, sink),
    new Promise<void>((resolve) => {
      timer = setTimeout(() => {
        console.warn(`[ai] 应答超时，释放频道队列: ${trigger.storedChannel}`);
        sink.typing(trigger.storedChannel, false);
        resolve();
      }, PACE.respondTimeoutMs);
    }),
  ]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

export function queueRespond(trigger: Trigger, sink: ReplySink): void {
  const q = queues.get(trigger.storedChannel) ?? { chain: Promise.resolve(), pending: 0 };
  if (q.pending >= PACE.queuePendingMax) return;
  q.pending += 1;
  q.chain = q.chain
    .then(() => respondWithTimeout(trigger, sink))
    .catch((error) => console.warn("[ai] 应答失败:", error instanceof Error ? error.message : error))
    .finally(() => {
      q.pending -= 1;
    });
  queues.set(trigger.storedChannel, q);
}
