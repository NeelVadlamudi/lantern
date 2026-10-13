// Service-day label, computed at view time (never hard-coded):
//   "Yesterday"  only when the file's service date equals (today in America/New_York) − 1 day;
//   otherwise    the weekday + date, e.g. "Mon, Oct 5".
// Sentence form (start of a sentence): "Yesterday" / "On Mon, Oct 5".
// Mid-sentence form:                  "yesterday" / "on Mon, Oct 5".
// Pure functions (no DOM) so tests/daylabel.test.mjs can run them in Node.

export const BOARD_TZ = "America/New_York";

const ISO = /^(\d{4})-(\d{2})-(\d{2})$/;

// "2026-10-06", "2026-10-06T00:00:00Z", Date (date part, UTC) -> "2026-10-06" | null
export function isoDay(v) {
  if (v == null) return null;
  if (v instanceof Date) return Number.isNaN(v.getTime()) ? null : v.toISOString().slice(0, 10);
  if (typeof v === "number" && Number.isFinite(v)) return new Date(v).toISOString().slice(0, 10); // epoch ms (DuckDB DATE)
  const s = String(v).trim().slice(0, 10);
  return ISO.test(s) ? s : null;
}

// Calendar date "YYYY-MM-DD" of the instant `now` in `tz`.
export function todayIn(now = new Date(), tz = BOARD_TZ) {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" })
      .formatToParts(now).map((x) => [x.type, x.value])
  );
  return `${p.year}-${p.month}-${p.day}`;
}

// Whole days from civil date a to civil date b (b − a), both "YYYY-MM-DD".
export function dayDiff(a, b) {
  const [ya, ma, da] = a.split("-").map(Number);
  const [yb, mb, db] = b.split("-").map(Number);
  return Math.round((Date.UTC(yb, mb - 1, db) - Date.UTC(ya, ma - 1, da)) / 86400000);
}

// "2026-10-05" -> "Mon, Oct 5" (civil date; no time zone shift).
export function shortDate(day) {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d, 12)).toLocaleDateString("en-US", { timeZone: "UTC", weekday: "short", month: "short", day: "numeric" });
}

// serviceDate: the file's service date. Returns null when it is missing or unreadable.
export function serviceDayLabel(serviceDate, now = new Date(), tz = BOARD_TZ) {
  const day = isoDay(serviceDate);
  if (!day) return null;
  const today = todayIn(now, tz);
  const isYesterday = dayDiff(day, today) === 1;
  const date = shortDate(day);
  return {
    day,
    today,
    isYesterday,
    label: isYesterday ? "Yesterday" : date,          // headers, segmented control
    sentence: isYesterday ? "Yesterday" : `On ${date}`, // start of a sentence
    inline: isYesterday ? "yesterday" : `on ${date}`,   // mid-sentence
  };
}
