// Local-time helpers. Every game clock (day, Sunday-start week, month) runs in
// the establishment's local time zone. Launch is New Jersey only (D9), so the
// engine uses one zone; see GameConfig.timeZone.

export const DAY_MS = 24 * 60 * 60 * 1000;
export const HOUR_MS = 60 * 60 * 1000;

export interface LocalDate {
  year: number;
  month: number; // 1-12
  day: number; // 1-31
  weekday: number; // 0 = Sunday
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  let f = formatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone,
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      second: "numeric",
      hourCycle: "h23",
      weekday: "short",
    });
    formatters.set(timeZone, f);
  }
  return f;
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function parts(ms: number, timeZone: string) {
  const out: Record<string, string> = {};
  for (const p of formatter(timeZone).formatToParts(new Date(ms))) out[p.type] = p.value;
  return {
    year: Number(out.year),
    month: Number(out.month),
    day: Number(out.day),
    hour: Number(out.hour),
    minute: Number(out.minute),
    second: Number(out.second),
    weekday: WEEKDAYS.indexOf(out.weekday),
  };
}

export function localDate(ms: number, timeZone: string): LocalDate {
  const p = parts(ms, timeZone);
  return { year: p.year, month: p.month, day: p.day, weekday: p.weekday };
}

const pad = (n: number) => String(n).padStart(2, "0");

/** "YYYY-MM-DD" in local time. */
export function dayKey(ms: number, timeZone: string): string {
  const d = localDate(ms, timeZone);
  return `${d.year}-${pad(d.month)}-${pad(d.day)}`;
}

/** "YYYY-MM" in local time. */
export function monthKey(ms: number, timeZone: string): string {
  const d = localDate(ms, timeZone);
  return `${d.year}-${pad(d.month)}`;
}

/** The local date ("YYYY-MM-DD") of the Sunday that starts this week. Weeks never reset at month change (D10). */
export function weekKey(ms: number, timeZone: string): string {
  const d = localDate(ms, timeZone);
  const sunday = new Date(Date.UTC(d.year, d.month - 1, d.day) - d.weekday * DAY_MS);
  return `${sunday.getUTCFullYear()}-${pad(sunday.getUTCMonth() + 1)}-${pad(sunday.getUTCDate())}`;
}

/** Offset of the zone from UTC at instant ms, in ms (e.g. -5h for EST). */
function zoneOffset(ms: number, timeZone: string): number {
  const p = parts(ms, timeZone);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return asUtc - Math.floor(ms / 1000) * 1000;
}

/** UTC instant of local midnight on the given local date. */
export function localMidnight(year: number, month: number, day: number, timeZone: string): number {
  const naive = Date.UTC(year, month - 1, day);
  let guess = naive - zoneOffset(naive, timeZone);
  guess = naive - zoneOffset(guess, timeZone);
  return guess;
}

/** UTC instant when the local month after `key` ("YYYY-MM") begins. */
export function startOfNextMonth(key: string, timeZone: string): number {
  const [y, m] = key.split("-").map(Number);
  return m === 12 ? localMidnight(y + 1, 1, 1, timeZone) : localMidnight(y, m + 1, 1, timeZone);
}
