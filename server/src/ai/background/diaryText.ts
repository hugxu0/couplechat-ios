export function sanitizeDiaryText(raw: string): string {
  return raw
    .trim()
    .replace(/^(?:#{1,6}\s*)?(?:大橘日记|日记)\s*[:：]?\s*/i, "")
    .replace(/^(?:\d{4}\s*[年./-]\s*\d{1,2}\s*[月./-]\s*\d{1,2}\s*日?|\d{1,2}\s*月\s*\d{1,2}\s*日)(?:\s*(?:星期|周)[一二三四五六日天])?\s*[,，。:：-]?\s*/u, "")
    .trim();
}
