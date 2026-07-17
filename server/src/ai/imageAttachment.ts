// 将「当前问题」与相关图片一并交给对话主模型（多模态），不再走独立识图转写。

import { latestImageGroup, recentMessages } from "./conversation/log";

export type ImageAttachMode = "none" | "current" | "recent_group";

export interface ImageAttachmentPlan {
  mode: ImageAttachMode;
  urls: string[];
  messageIds: string[];
  reason: string;
}

const MAX_IMAGES = 9;
/** 在最近多少条消息里找连续图片组 */
const RECENT_SCAN = 50;

/**
 * 问题是否在明确指代/需要看图（用于开跑前预附着最近图组）。
 * 偏精确：避免普通闲聊（如「好看吗」「你看」）误带上历史图做多模态。
 */
export function questionLikelyNeedsImages(question: string): boolean {
  const q = question.replace(/\s+/g, " ").trim();
  if (q.length < 2) return false;

  // 明确出现图像类词
  if (/(?:图|照片|截图|拍照|相册|pic|photo|image|img|screenshot)/i.test(q)) return true;

  // 量词指代「张」且带视觉意图（这张/那几张/哪张…）
  if (/(这|那|哪)(一|几)?张/.test(q)) return true;

  // 时间/位置指代 + 图相关动作
  if (/(刚才|刚发|上面|下面|前面|上一条).{0,6}(图|照片|截图|那张|这张)/.test(q)) return true;

  // 明确看图指令
  if (/(帮我看图|看看这张|看看那张|识别一下图|读一下图|图里|照片里|截图里)/.test(q)) return true;
  if (/(对比|比较).{0,8}(图|张|照片)/.test(q)) return true;

  return false;
}

export function normalizeImageUrls(urls: string[] | undefined, max = MAX_IMAGES): string[] {
  return [...new Set((urls ?? []).filter(Boolean))].slice(0, max);
}

export async function resolveRecentImageGroup(input: {
  storedChannel: string;
  excludeMessageId?: string;
  maxImages?: number;
}): Promise<{ urls: string[]; messageIds: string[] }> {
  const maxImages = Math.max(1, Math.min(MAX_IMAGES, input.maxImages ?? MAX_IMAGES));
  const recent = (await recentMessages(input.storedChannel, RECENT_SCAN))
    .filter((message) => message.id !== input.excludeMessageId);
  const group = latestImageGroup(recent, maxImages);
  return {
    urls: group.urls,
    messageIds: group.messages.map((message) => message.id),
  };
}

/**
 * 开跑前决定是否把图片与问题一起塞进主模型。
 * - 本条有图 → current
 * - 本条无图但问题像在问图 → recent_group
 * - 否则 none（仍可通过工具请求二次多模态）
 */
export async function resolveImageAttachment(input: {
  storedChannel: string;
  currentMessageId?: string;
  currentImageUrls?: string[];
  question: string;
  forceRecent?: boolean;
  maxImages?: number;
}): Promise<ImageAttachmentPlan> {
  const maxImages = Math.max(1, Math.min(MAX_IMAGES, input.maxImages ?? MAX_IMAGES));
  const current = normalizeImageUrls(input.currentImageUrls, maxImages);
  if (current.length) {
    return {
      mode: "current",
      urls: current,
      messageIds: input.currentMessageId ? [input.currentMessageId] : [],
      reason: "current_message",
    };
  }

  const needs = input.forceRecent || questionLikelyNeedsImages(input.question);
  if (!needs) {
    return { mode: "none", urls: [], messageIds: [], reason: "not_needed" };
  }

  const group = await resolveRecentImageGroup({
    storedChannel: input.storedChannel,
    excludeMessageId: input.currentMessageId,
    maxImages,
  });
  if (!group.urls.length) {
    return { mode: "none", urls: [], messageIds: [], reason: "no_recent_images" };
  }
  return {
    mode: "recent_group",
    urls: group.urls,
    messageIds: group.messageIds,
    reason: input.forceRecent ? "tool_force" : "question_refers_images",
  };
}

export function sameImageSet(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  const left = [...a].sort();
  const right = [...b].sort();
  return left.every((url, index) => url === right[index]);
}
