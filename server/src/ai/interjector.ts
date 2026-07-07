// 后台主动插话：couple 频道攒够一定量的真人消息后，后台判断「大橘现在有没有话想说」。
// 没有一点想说就安静，绝不为了存在感硬找话题。
// 移植自旧后端 chat/src/ai/assistant.js::interject 的 prompt 设计与节奏——
// 核心是「真的有话想说才开口」，不是定时巡逻找话题的客服。

import type { Server } from "socket.io";
import { chat, extractJson } from "./provider";
import { recentMessages, compactLine, type LogMessage } from "./chatLog";
import { recallSafe } from "./recall";
import { ensureDailyMood } from "./nightly";
import { getDoc } from "./memoryStore";
import { summaryText } from "./sessionSummary";
import { personaCore } from "./persona";
import { accounts } from "./memoryStore";
import { createAiMessage } from "../chat/messageService";
import { pushCoupleMessageToUnavailableRecipients } from "../push/pushService";
import { aiEnabled } from "./provider";
import { GEN, MEMORY } from "./params";

const INTERJECT_EVERY = 8;                         // 攒够 8 条真人消息考虑一次
const COOLDOWN_MS = 2 * 60 * 60 * 1000;            // 距上次插话 2 小时冷却
const CONTEXT_LINES = 20;                          // 拉多少条最近聊天

let msgCount = 0;
let lastInterjectTs = 0;
let running = false;

// persona.ts 导出的是函数，不是字符串；这里给 interject 提供一个轻量版的人设行。
// （如果以后 persona.ts 改成导出字符串直接复用，删掉这段。）
function personaLine(): string {
  const names = accounts().map((a) => a.name).join("和") || "这对情侣";
  return `你叫「大橘」，是 ${names} 共同养的一只橘猫，也是会记住他们、陪着他们慢慢变熟的小伙伴。`;
}

const SYSTEM = [
  personaLine(),
  "你在后台默默观察两位主人的聊天，像一个真实在场、有自己想法的朋友/伴侣，不是定时巡逻找话题的客服——只在你真的「有话想说」时才开口。",
  "【不要给记忆加戏】记忆条目只是精炼过的一句话事实，不带来龙去脉；只能说条目本身写到的内容，不能自己脑补是谁说的、什么时候、当时什么情景这类没给的细节——编造具体情节比不提这件事更糟。",
  "【什么时候算「有话想说」——这些只是例子，启发你怎么像人一样反应，不要套模板、不要每次都是同一种调调】",
  "- 纠正/提醒：他们正聊的事和你记忆里的不一样，或者他们好像忘了什么你记得的事（比如之前提过的约定、习惯、纪念日）→ 像突然想起来一样自然地提一句，不要说「根据我的记录/长期记忆显示」这种机械话，要像是你自己脑子里冒出来的。",
  "- 被「秀到」的真实反应：两人在撒糖、互相腻歪、说着说着就甜了、有夫妻相的瞬间 → 可以被膈应到，吐槽一句「真受不了你们俩了」「又来了」「够了啊」，带点嫌弃又想笑的语气，不是在旁边鼓掌叫好。",
  "- 接住一个被忽略的小情绪、或者让某个人觉得被记得——结合具体的偏好或近期事件说一句贴心的话，但别说「你们真好」「注意休息」这种谁都能说、跟这对情侣无关的空话。",
  "- 发现一个有意思的细节、矛盾的说法、突然 get 到了什么梗 → 像旁观的朋友一样自然接一句。",
  "判断要不要说：闲聊顺畅、你也没有更懂他们的话可补、没有任何真实反应想表达时，就安静待着（shouldReply:false）。开口的标准是「我真的有东西想说」，不是为了维持存在感硬找话题。",
  "不要抢话，不要复述聊天原文，不要长篇总结或说教，一次只说一两句，像人发一条消息那样自然、随性，不要每次语气都一个模。",
  '只输出 JSON：{"shouldReply":true或false,"reply":"要插入聊天的一句话"}',
  '如果不该插话，输出 {"shouldReply":false,"reply":""}。',
].join("\n");

function buildUser(recent: LogMessage[], recalled: { factsContext: string; episodesContext: string }, mood: string): string {
  const parts: string[] = [];
  if (recalled.factsContext) parts.push(`【听着聊天想起来的】${recalled.factsContext}`);
  if (recalled.episodesContext) parts.push(`【相关事件记忆】${recalled.episodesContext}`);
  if (mood) parts.push(`【大橘今日心情】${mood}`);
  const lines = recent
    .filter((m) => m.kind !== "system")
    .map((m) => compactLine(m, 180))
    .filter(Boolean)
    .join("\n");
  parts.push(`【最近聊天】\n${lines || "暂无最近聊天"}`);
  parts.push("请判断大橘现在是否要插话。");
  return parts.join("\n\n");
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function maybeInterject(io: Server, channel: string): Promise<void> {
  if (!aiEnabled()) return;
  if (running) return;
  msgCount += 1;
  if (msgCount < INTERJECT_EVERY) return;
  // 冷却期：距上次插话必须 ≥ COOLDOWN_MS
  if (lastInterjectTs > 0 && Date.now() - lastInterjectTs < COOLDOWN_MS) {
    msgCount = 0;
    return;
  }

  running = true;
  try {
    // 召回用「最近几条用户消息」当查询句
    const recent = await recentMessages(channel, CONTEXT_LINES);
    const recentUser = recent.filter((m) => m.kind === "user" && m.type === "text" && m.text.trim()).slice(-3);
    const query = recentUser.map((m) => (m.text || "").slice(0, 80)).join(" ").slice(0, 400);
    const [recalled, mood] = await Promise.all([
      query ? recallSafe(query, channel).catch(() => ({ factsContext: "", episodesContext: "" })) : Promise.resolve({ factsContext: "", episodesContext: "" }),
      ensureDailyMood().catch(() => ""),
    ]);

    const out = await chat({
      profile: "task",
      system: SYSTEM,
      user: buildUser(recent, recalled, mood),
      gen: GEN.interject,
    });
    const parsed = extractJson<{ shouldReply?: boolean; reply?: string }>(out);
    if (!parsed || !parsed.shouldReply) {
      msgCount = 0;
      return;
    }
    const reply = typeof parsed.reply === "string" ? parsed.reply.trim().slice(0, 500) : "";
    if (!reply) {
      msgCount = 0;
      return;
    }

    lastInterjectTs = Date.now();
    msgCount = 0;
    console.log(`[ai] 大橘主动插话：${reply.slice(0, 60)}`);

    // 模拟打字延迟，让回复不像被定时器吐出来的
    await sleep(700 + Math.floor(Math.random() * 700));
    const message = await createAiMessage("couple", reply);
    io.to("channel:couple").emit("message:new", message);
    void pushCoupleMessageToUnavailableRecipients(message);
  } catch (error) {
    console.warn("[ai] 插话失败:", error instanceof Error ? error.message : error);
    msgCount = 0;
  } finally {
    running = false;
  }
}