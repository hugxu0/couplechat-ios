export function validTimezone(timezone: string): boolean {
  try { new Intl.DateTimeFormat("en", { timeZone: timezone }).format(); return true; } catch { return false; }
}

interface DateParts { year: number; month: number; day: number; hour: number; minute: number; second: number }

export function localParts(timestamp: number, timezone: string): DateParts {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(timestamp));
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return {
    year: Number(value.year),
    month: Number(value.month),
    day: Number(value.day),
    hour: Number(value.hour),
    minute: Number(value.minute),
    second: Number(value.second),
  };
}

export function zonedDateTimeToUtc(parts: DateParts, timezone: string): number {
  const desired = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
  let guess = desired;
  for (let index = 0; index < 3; index += 1) {
    const actual = localParts(guess, timezone);
    const represented = Date.UTC(actual.year, actual.month - 1, actual.day, actual.hour, actual.minute, actual.second);
    const correction = desired - represented;
    guess += correction;
    if (correction === 0) break;
  }
  return guess;
}

export function monthRange(month: string, timezone: string): { start: number; end: number } | null {
  const match = /^(\d{4})-(\d{2})$/.exec(month);
  if (!match) return null;
  const year = Number(match[1]);
  const monthNumber = Number(match[2]);
  if (monthNumber < 1 || monthNumber > 12) return null;
  const nextYear = monthNumber === 12 ? year + 1 : year;
  const nextMonth = monthNumber === 12 ? 1 : monthNumber + 1;
  return {
    start: zonedDateTimeToUtc({ year, month: monthNumber, day: 1, hour: 0, minute: 0, second: 0 }, timezone),
    end: zonedDateTimeToUtc({ year: nextYear, month: nextMonth, day: 1, hour: 0, minute: 0, second: 0 }, timezone),
  };
}

export function validEventRange(input: {
  startAt: number;
  endAt: number;
  timezone: string;
  allDay: boolean;
}): boolean {
  if (!Number.isSafeInteger(input.startAt) || !Number.isSafeInteger(input.endAt) || input.endAt <= input.startAt) {
    return false;
  }
  if (!validTimezone(input.timezone)) return false;
  if (!input.allDay) return true;
  const start = localParts(input.startAt, input.timezone);
  const end = localParts(input.endAt, input.timezone);
  return start.hour === 0 && start.minute === 0 && start.second === 0
    && end.hour === 0 && end.minute === 0 && end.second === 0;
}
