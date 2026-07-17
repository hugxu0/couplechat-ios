// 共享的短寒暄/低信息量判定，供上下文微段与 Memory 抽取复用。

/** 贴纸、单字附和等：不进日总览微段、不送 Memory 整理模型。 */
export function isLowSignalText(text: string): boolean {
  const t = text.replace(/\s+/g, "").trim();
  if (!t) return true;
  if (t.length > 8) return false;
  return /^(嗯+|啊+|哦+|哈+|呵+|嘿+|额+|唔+|好+|嗯嗯|哈哈+|嘿嘿+|呵呵+|ok+|OK+|好的|收到|在|1|？|\?|。|！|!|…|\.{2,}|😂+|🤣+|😅+|😊+|👍+|🙏+)+$/u.test(t);
}
