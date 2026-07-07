// 冲突检测：couple 频道收到真人消息时后台跑（fire-and-forget，不经 @召唤）。
// 检测到吵架迹象 → 主动发一条介入消息。
//
// 安全设计（移植自旧后端 chat/src/chat/behaviors/conflict.js + assistant.assessConflictAndReply）：
//   - 宁可漏判，不要误判：阈值 0.7；单条语气存疑不算。
//   - ≥2 条用户消息 且 ≥2 个不同发送者（防自言自语误判）。
//   - 距上次检测 ≥3 条新消息（增量门控）。
//   - 上次介入后 15 分钟冷却期。
//   - 互斥锁防并发。

import type { Server } from "socket.io";
import { chat, extractJson } from "./provider";
import { recentMessages, compactLine, type LogMessage } from "./chatLog";
import { createAiMessage } from "../chat/messageService";
import { pushCoupleMessageToUnavailableRecipients } from "../push/pushService";
import { aiEnabled } from "./provider";
import { GEN } from "./params";

const SPEAK_SILENCE_MS = 15 * 60 * 1000;       // 上次介入后 15 分钟冷却
const MIN_NEW_MESSAGES = 3;                      // 距上次检测至少 3 条新消息
const CONFLICT_THRESHOLD = 0.7;                  // 置信度阈值
const MIN_WINDOW = 12;                           // 拉多少条最近聊天给模型看

let lastCheckMsgTs = 0;                          // 上次检测到的最后一条消息 ts（增量游标）
let lastConflictTs = 0;                          // 上次介入时间
let running = false;

const SYSTEM_PROMPT = [
  "你是大橘，这对情侣的猫伴侣，正在后台默默判断最近的聊天有没有冲突或情绪紧张。",
  "",
  "【哪些算冲突信号——按类别识别，而不是死记某几句话】",
  "- 情绪降温/回避：本来聊得好好的，突然变单字回复、不接话、转移话题躲开当前的事。",
  "- 阴阳怪气/反讽：表面顺从但语气不对劲（「你说的都对」「随你」「可以啊」），实际是憋着不满。",
  "- 攻击性/翻旧账：贬低、嘲讽、翻旧账翻出以前的事来扎对方。",
  "- 比较打压：拿别人/前任/「别人家的」来比对方，暗示对方不够好。",
  "- 冷暴力：已读不回好几轮后突然冒出一句带刺的话，或长时间沉默后语气骤变。",
  "- 单方面情绪爆发：突然发火、连续抱怨、明显的叹气/无奈语气。",
  "",
  "【哪些不算——避免误判，这些很容易被错当成吵架】",
  "- 正常的意见不合/讨论分歧：语气平和地各说各的看法，没有攻击和阴阳怪气。",
  "- 撒娇式抱怨/玩笑吐槽：带笑意的「哼」「你又这样」，对方也顺着梗接话，气氛是软的不是硬的。",
  "- 一起吐槽第三方（「他有病吧」「真是服了」）：这是统一战线，不是互相攻击，不算冲突。",
  "- 单纯一方在忙/心不在焉导致回复变短：没有针对对方的情绪色彩，只是没空。",
  "",
  "【先分析再下结论——reason 字段必须是真分析，不是走过场】",
  "在 reason 里分别说清楚：A 现在的情绪状态和可能在意的点是什么、B 现在的情绪状态和可能在意的点是什么、这次摩擦的导火索/深层原因大概是什么（比如：表面在吵谁去倒垃圾，深层其实是「觉得对方最近不上心、自己的付出没被看见」）。想清楚这些再决定 conflict 和 confidence——confidence 不是凭感觉给的数字，是这次分析有多确信「这真的是需要介入的冲突」。",
  "",
  "【宁可漏判，不要误判】",
  "拿不准就 conflict=false。介入错了（把玩笑当吵架、把忙碌当冷暴力）比漏过一次轻微摩擦伤害大得多——被误判的人会觉得被冒犯，以后大橘说什么都没人听了。",
  "只有当冲突信号明确、且不止一条消息带情绪（升级趋势或双方都有情绪）时才 conflict=true；单独一句语气存疑的话，不算。",
  "",
  "【回复要求——短、具体、可跳过】",
  "reply 最多 2~3 句、120 字以内。只说两件事：①一句话点破这次各自真正在意的是什么（必须引用聊天里具体的事，不点名重复伤人原话）；②一个立刻能做的具体小动作。",
  "【绝对禁止】「别吵啦」「抱一抱」「和好吧」「多沟通」「互相理解一下」这类没有信息量的劝和话——一个字都不要出现。",
  "硬性检验：如果你的 reply 换到任何一对情侣的任何一次争吵里都说得通，那它就是空话，删掉重写；还是写不出具体内容，就把 conflict 设为 false、reply 留空——不说话永远好过说废话。",
  "语气仍是大橘：大白话、带点猫感，不甩心理学术语，不站队、不评判谁对谁错。",
  '只输出 JSON：{"conflict":boolean,"confidence":0..1,"reason":"对双方情绪和深层原因的分析","reply":"" 或 "中文回复"}',
].join("\n");

function buildUser(recent: LogMessage[]): string {
  const lines = recent
    .filter((m) => m.kind === "user" && m.type === "text" && m.text && m.text.trim())
    .slice(-MIN_WINDOW)
    .map((m) => compactLine(m, 180))
    .filter(Boolean)
    .join("\n");
  return [
    `最近聊天：\n${lines || "（无）"}`,
    "请先在 reason 里分析双方此刻的情绪状态和可能的深层原因，再判断这是不是真的需要介入的冲突信号，给出 conflict 和 confidence。",
    "确实需要介入才写 reply（短、具体、点到为止）；拿不准或写不出具体内容，conflict=false、reply 留空。",
  ].join("\n\n");
}

export async function maybeCheck(io: Server, channel: string): Promise<void> {
  if (!aiEnabled()) return;
  if (running) return;

  const recent = await recentMessages(channel, MIN_WINDOW + 10);
  const userMsgs = recent.filter((m) => m.kind === "user" && m.type === "text" && m.text && m.text.trim());
  if (userMsgs.length < 2) return;

  // 门控：≥2 个不同发送者
  const senders = new Set(userMsgs.map((m) => m.sender));
  if (senders.size < 2) return;

  // 增量门控：距上次检测 ≥3 条新消息（首次启动时 lastCheckMsgTs=0，跳过此门）
  if (lastCheckMsgTs > 0) {
    const newMsgs = userMsgs.filter((m) => m.ts > lastCheckMsgTs);
    if (newMsgs.length < MIN_NEW_MESSAGES) return;
  }

  // 冷却期
  if (lastConflictTs > 0 && Date.now() - lastConflictTs < SPEAK_SILENCE_MS) return;

  running = true;
  try {
    const out = await chat({
      profile: "task",
      system: SYSTEM_PROMPT,
      user: buildUser(recent),
      gen: GEN.conflict,
    });
    const parsed = extractJson<{ conflict?: boolean; confidence?: number; reason?: string; reply?: string }>(out);
    if (!parsed || !parsed.conflict) return;
    const confidence = Math.max(0, Math.min(1, Number(parsed.confidence) || 0));
    if (confidence < CONFLICT_THRESHOLD) return;
    const reply = typeof parsed.reply === "string" ? parsed.reply.trim().slice(0, 300) : "";
    if (!reply) return;

    lastConflictTs = Date.now();
    console.log(`[ai] 冲突介入 confidence=${confidence.toFixed(2)} reason=${(parsed.reason ?? "").slice(0, 80)}`);

    // 主动发出介入消息（不经 @召唤，直接在 couple 频道插话）
    const message = await createAiMessage("couple", reply);
    io.to("channel:couple").emit("message:new", message);
    void pushCoupleMessageToUnavailableRecipients(message);
  } catch (error) {
    console.warn("[ai] 冲突检测失败:", error instanceof Error ? error.message : error);
  } finally {
    lastCheckMsgTs = userMsgs[userMsgs.length - 1]?.ts ?? Date.now();
    running = false;
  }
}