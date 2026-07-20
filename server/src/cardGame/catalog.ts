export const cardRarities = ["common", "rare", "epic", "legendary"] as const;
export type CardRarity = (typeof cardRarities)[number];

export const cardCategories = [
  "intimacy",
  "money",
  "emotion",
  "choice",
  "support",
] as const;
export type CardCategory = (typeof cardCategories)[number];

export type CardEffectKind = "timed" | "instant" | "modifier" | "response";

export interface CardDefinition {
  key: string;
  title: string;
  category: CardCategory;
  rarity: CardRarity;
  summary: string;
  icon: string;
  effectKind: CardEffectKind;
  durationMs: number | null;
  modifier: "addTime" | "postpone" | "copy" | "qiankun" | null;
}

const rarityDuration: Record<CardRarity, number> = {
  common: 5 * 60_000,
  rare: 10 * 60_000,
  epic: 20 * 60_000,
  legendary: 30 * 60_000,
};

const rarityLabels: Record<CardRarity, string> = {
  common: "普通",
  rare: "稀有",
  epic: "史诗",
  legendary: "传说",
};

function timedSet(
  key: string,
  title: string,
  category: CardCategory,
  icon: string,
  summaries?: Partial<Record<CardRarity, string>>,
): CardDefinition[] {
  return cardRarities.map((rarity) => ({
    key,
    title,
    category,
    rarity,
    summary: summaries?.[rarity] ?? `${rarityLabels[rarity]}·${title}`,
    icon,
    effectKind: "timed" as const,
    durationMs: rarityDuration[rarity],
    modifier: null,
  }));
}

function timedSetWithDurations(
  key: string,
  title: string,
  category: CardCategory,
  icon: string,
  durations: Record<CardRarity, number>,
  summaries?: Partial<Record<CardRarity, string>>,
): CardDefinition[] {
  return cardRarities.map((rarity) => ({
    key,
    title,
    category,
    rarity,
    summary: summaries?.[rarity] ?? rarityLabels[rarity] + "·" + title,
    icon,
    effectKind: "timed" as const,
    durationMs: durations[rarity],
    modifier: null,
  }));
}

function instantSet(
  key: string,
  title: string,
  category: CardCategory,
  icon: string,
  summaries: Record<CardRarity, string>,
): CardDefinition[] {
  return cardRarities.map((rarity) => ({
    key,
    title,
    category,
    rarity,
    summary: summaries[rarity],
    icon,
    effectKind: "instant" as const,
    durationMs: null,
    modifier: null,
  }));
}

const intimacyCards = [
  ...timedSet("intimacy_kiss", "亲吻爱抚券", "intimacy", "heart.fill", {
    common: "亲吻爱抚 5 分钟",
    rare: "亲吻爱抚 10 分钟",
    epic: "亲吻爱抚 20 分钟",
    legendary: "亲吻爱抚 30 分钟",
  }),
  ...timedSet("intimacy_massage", "按摩券", "intimacy", "hands.clap.fill", {
    common: "按摩 5 分钟",
    rare: "按摩 10 分钟",
    epic: "按摩 20 分钟",
    legendary: "全身按摩 30 分钟",
  }),
  ...timedSet("intimacy_shower", "帮洗澡券", "intimacy", "shower.fill", {
    common: "帮洗澡 5 分钟",
    rare: "帮洗澡 10 分钟",
    epic: "完整帮洗澡 20 分钟",
    legendary: "帮洗澡及后续照顾 30 分钟",
  }),
  ...timedSet("intimacy_oral", "口部亲密券", "intimacy", "mouth.fill", {
    common: "口部亲密 5 分钟",
    rare: "口部亲密 10 分钟",
    epic: "口部亲密 20 分钟",
    legendary: "口部亲密 30 分钟",
  }),
  ...instantSet("intimacy_theme", "情趣主题券", "intimacy", "sparkles", {
    common: "选择姿势",
    rare: "选择穿搭",
    epic: "选择情趣用品",
    legendary: "在双方已同意范围内满足一项自选需求",
  }),
  ...timedSet("intimacy_lead", "对方主动券", "intimacy", "person.fill.questionmark", {
    common: "对方主动 5 分钟",
    rare: "对方主动 10 分钟",
    epic: "对方主动 20 分钟",
    legendary: "对方主动 30 分钟",
  }),
];

const moneyCards = instantSet("money_red_packet", "红包卡", "money", "yensign.circle.fill", {
  common: "发给对方 5 元红包",
  rare: "发给对方 10 元红包",
  epic: "发给对方 20 元红包",
  legendary: "请对方吃一顿饭",
});

const emotionCards = [
  ...instantSet("emotion_reconcile", "和好券", "emotion", "heart.circle.fill", {
    common: "立即发和好消息",
    rare: "立即发语音道歉",
    epic: "立即发起 15 分钟视频沟通",
    legendary: "立即发起 30 分钟和好流程",
  }),
  ...instantSet("emotion_apology", "道歉券", "emotion", "hands.sparkles.fill", {
    common: "发一段认真道歉文字",
    rare: "说明做错了什么和怎么改",
    epic: "语音道歉并完成一次实际补偿",
    legendary: "完成问题、影响、道歉、改法四步",
  }),
  ...instantSet("emotion_reassurance", "安心券", "emotion", "shield.lefthalf.filled", {
    common: "回答一个在意的问题",
    rare: "回答三个问题",
    epic: "说明近期安排和真实想法",
    legendary: "进行 30 分钟安全感沟通",
  }),
  ...timedSetWithDurations("emotion_cooldown", "冷却期券", "emotion", "pause.circle.fill", {
    common: 30 * 60_000,
    rare: 2 * 60 * 60_000,
    epic: 8 * 60 * 60_000,
    legendary: 24 * 60 * 60_000,
  }, {
    common: "暂停争论 30 分钟",
    rare: "暂停 2 小时，并发送‘我还在’",
    epic: "暂停到当天晚上，并约定恢复时间",
    legendary: "最长暂停 24 小时，并提前约定恢复方式",
  }),
  ...instantSet("emotion_letter", "情书券", "emotion", "envelope.open.fill", {
    common: "发 50 字以上的专属文字",
    rare: "发 150 字以上的专属情话",
    epic: "情话文字加语音或照片",
    legendary: "写一封完整情书并说出未来愿望",
  }),
];

const choiceCards = [
  ...instantSet("choice_meal", "餐食选择权卡", "choice", "fork.knife", {
    common: "裁决吃什么或喝什么",
    rare: "裁决一顿正餐",
    epic: "裁决一次约会餐食安排",
    legendary: "裁决整次见面的餐食方案",
  }),
  ...instantSet("choice_entertainment", "娱乐选择权卡", "choice", "film.fill", {
    common: "裁决电影、音乐或游戏",
    rare: "裁决一次娱乐项目",
    epic: "裁决一段约会娱乐安排",
    legendary: "裁决整次见面的娱乐方案",
  }),
  ...instantSet("choice_location", "地点选择权卡", "choice", "mappin.and.ellipse", {
    common: "裁决餐厅或咖啡店",
    rare: "裁决一次约会地点",
    epic: "裁决一段出行地点安排",
    legendary: "裁决整次见面的主要地点",
  }),
  ...instantSet("choice_itinerary", "行程选择权卡", "choice", "list.bullet.rectangle.portrait.fill", {
    common: "裁决先做什么后做什么",
    rare: "裁决当天一段行程",
    epic: "裁决当天约会路线",
    legendary: "裁决整次见面的流程",
  }),
  ...instantSet("choice_hotel", "酒店安排选择权卡", "choice", "bed.double.fill", {
    common: "裁决早餐或活动顺序",
    rare: "裁决房间布置的一项内容",
    epic: "裁决酒店内的活动安排",
    legendary: "裁决酒店约会的完整安排",
  }),
];

const postponeDays: Record<CardRarity, number> = {
  common: 1,
  rare: 3,
  epic: 7,
  legendary: 30,
};

const supportCards: CardDefinition[] = [
  ...cardRarities.map((rarity) => ({
    key: "support_add_time",
    title: "加时卡",
    category: "support" as const,
    rarity,
    summary: `为一项倒计时增加 ${rarityDuration[rarity] / 60_000} 分钟`,
    icon: "timer",
    effectKind: "modifier" as const,
    durationMs: rarityDuration[rarity],
    modifier: "addTime" as const,
  })),
  ...cardRarities.map((rarity) => ({
    key: "support_postpone",
    title: "延期卡",
    category: "support" as const,
    rarity,
    summary: "将一项效果延期 " + postponeDays[rarity] + " 天",
    icon: "calendar.badge.clock",
    effectKind: "modifier" as const,
    durationMs: postponeDays[rarity] * 24 * 60 * 60_000,
    modifier: "postpone" as const,
  })),
  ...cardRarities.map((rarity) => ({
    key: "support_copy",
    title: "复制卡",
    category: "support" as const,
    rarity,
    summary: "复制对方卡库中的一张卡",
    icon: "doc.on.doc.fill",
    effectKind: "modifier" as const,
    durationMs: null,
    modifier: "copy" as const,
  })),
  ...cardRarities.map((rarity) => ({
    key: "support_qiankun",
    title: "乾坤大挪移",
    category: "support" as const,
    rarity,
    summary: "将对方对自己使用的效果转移给对方",
    icon: "arrow.triangle.2.circlepath",
    effectKind: "response" as const,
    durationMs: null,
    modifier: "qiankun" as const,
  })),
];

export const cardCatalog: readonly CardDefinition[] = [
  ...intimacyCards,
  ...moneyCards,
  ...emotionCards,
  ...choiceCards,
  ...supportCards,
];

const cardIndex = new Map(cardCatalog.map((card) => [`${card.key}:${card.rarity}`, card]));

export function cardDefinition(key: string, rarity: string): CardDefinition | undefined {
  return cardIndex.get(`${key}:${rarity}`);
}

export function randomRarity(random: number): CardRarity {
  if (random < 0.60) return "common";
  if (random < 0.85) return "rare";
  if (random < 0.97) return "epic";
  return "legendary";
}

export function randomCardFor(rarity: CardRarity, random: number): CardDefinition {
  const candidates = cardCatalog.filter((card) => card.rarity === rarity);
  return candidates[Math.min(candidates.length - 1, Math.floor(random * candidates.length))];
}
