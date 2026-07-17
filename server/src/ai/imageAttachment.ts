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
 * 问题是否在指代/需要看图（用于开跑前预附着）。
 * 偏召回：公聊分条发图后再问，应尽量第一轮就带上图。
 */
export function questionLikelyNeedsImages(question: string): boolean {
  const q = question.replace(/\s+/g, " ").trim();
  if (!q) return false;
  if (/图|照片|截图|拍照|相册|pic|photo|image|img|screenshot/i.test(q)) return true;
  if (/(看|识别|辨认|翻译|读|念|念一下).{0,6}(下|一下|看)?$/.test(q) && q.length <= 16) return true;
  if (/(这|那|刚才|上面|下面|前面|刚发|上一).{0,8}(张|些|个)?/.test(q)
    && /(看|是什么|什么东西|啥|谁|哪|对比|比较|好看|意思|说的|写的|字)/.test(q)) {
    return true;
  }
  if (/(对比|比较|哪张|哪个更好|帮我看|看看这|看看那)/.test(q)) return true;
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
