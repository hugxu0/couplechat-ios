// 北京时间作息日工具：早 6 点切日，半夜聊天算「昨天」。海外服务器也不跑偏。

import { DAY_ROLLOVER_HOUR } from "./settings";

const BEIJING_OFFSET_MS = 8 * 60 * 60 * 1000;

export interface BeijingParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
}

export function beijingParts(ts: number = Date.now()): BeijingParts {
  const d = new Date(ts + BEIJING_OFFSET_MS);
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
  };
}

export function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

// 作息日日期串：北京时间往前拨 6 小时后取日期。
export function cycleDate(ts: number = Date.now()): string {
  const d = new Date(ts + BEIJING_OFFSET_MS - DAY_ROLLOVER_HOUR * 60 * 60 * 1000);
  return `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}`;
}

// 作息日的起止时间戳（[start, end)）。
export function cycleBounds(date: string): { start: number; end: number } {
  const [y, m, d] = date.split("-").map(Number);
  const start = Date.UTC(y, m - 1, d, DAY_ROLLOVER_HOUR) - BEIJING_OFFSET_MS;
  return { start, end: start + 24 * 60 * 60 * 1000 };
}

export function addDays(date: string, delta: number): string {
  const [y, m, d] = date.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + delta));
  return `${dt.getUTCFullYear()}-${pad2(dt.getUTCMonth() + 1)}-${pad2(dt.getUTCDate())}`;
}

export function beijingClock(ts: number): string {
  const p = beijingParts(ts);
  return `${pad2(p.hour)}:${pad2(p.minute)}`;
}

export function beijingDateTime(ts: number): string {
  const p = beijingParts(ts);
  return `${p.year}-${pad2(p.month)}-${pad2(p.day)} ${pad2(p.hour)}:${pad2(p.minute)}`;
}
