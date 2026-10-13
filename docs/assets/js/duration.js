// Durations: the two largest units among s, min, h, days, months (30 days), years (365 days).
//   - zero units are dropped ("1 h", not "1 h 0 min")
//   - what is cut below the second unit is rounded to the nearest second unit (halves up) and
//     carried: 3655 s -> "1 h 1 min", 86380 s -> "1 day"; 3599 s stays "59 min 59 s"
//   - below one minute only seconds show, rounded to the nearest whole second (59.5 s -> "1 min")
//   - 12 months carry into a year (a year shows at most 11 months)
// Negative values get a minus sign (U+2212); { signed: true } adds "+" to positive values.
// Exact seconds belong in a title/tooltip: see exactSeconds().

const MIN = 60, HOUR = 3600, DAY = 86400, MONTH = 30 * DAY, YEAR = 365 * DAY;

// Largest first. `per` = how many of the next smaller unit make one of this unit (for carrying).
const UNITS = [
  { s: YEAR, one: "year", many: "years", per: 12 },     // 12 months carry to a year
  { s: MONTH, one: "month", many: "months", per: 30 },  // 30 days
  { s: DAY, one: "day", many: "days", per: 24 },
  { s: HOUR, one: "h", many: "h", per: 60 },
  { s: MIN, one: "min", many: "min", per: 60 },
  { s: 1, one: "s", many: "s", per: 1 },
];

// Half-up rounding that ignores float noise (29.999999999 counts as 30).
const roundHalfUp = (x) => Math.floor(Math.round(x * 1e6) / 1e6 + 0.5);

// Returns [[count, unitIndex], ...] (at most two, zero counts removed) for a non-negative value.
export function durationParts(seconds) {
  let v = Math.abs(Number(seconds));
  if (!Number.isFinite(v)) return null;
  for (let guard = 0; guard < 4; guard += 1) {
    if (v < MIN) {
      const n = roundHalfUp(v);
      if (n >= MIN) { v = n; continue; }          // 59.5 s -> 60 s -> "1 min"
      return [[n, UNITS.length - 1]];
    }
    const i = UNITS.findIndex((u) => v >= u.s);
    const U = UNITS[i], V = UNITS[i + 1];
    let a = Math.floor(v / U.s);
    let b = roundHalfUp((v - a * U.s) / V.s);
    if (b >= U.per) { a += 1; b = 0; }              // carry: 60 min -> 1 h, 12 months -> 1 year
    const total = a * U.s + b * V.s;
    const W = UNITS[i - 1];
    if (W && total >= W.s) { v = total; continue; } // rounded up into the next unit: re-express
    return [[a, i], [b, i + 1]].filter(([n]) => n > 0);
  }
  return [[0, UNITS.length - 1]];
}

export function formatDuration(seconds, { signed = false } = {}) {
  const n = Number(seconds);
  if (seconds == null || !Number.isFinite(n)) return "—";
  const parts = durationParts(n);
  const text = parts.length
    ? parts.map(([c, i]) => `${c} ${c === 1 ? UNITS[i].one : UNITS[i].many}`).join(" ")
    : "0 s";
  if (text === "0 s") return text;
  if (n < 0) return `\u2212${text}`;
  return signed ? `+${text}` : text;
}

// "15,068,522 s" for tooltips (exact to the second; one decimal only when it matters).
export function exactSeconds(seconds) {
  const n = Number(seconds);
  if (seconds == null || !Number.isFinite(n)) return "";
  const r = Math.round(n * 10) / 10;
  const s = Math.abs(r).toLocaleString("en-US", { maximumFractionDigits: Number.isInteger(r) ? 0 : 1 });
  return `${n < 0 ? "\u2212" : ""}${s} s`;
}

// Inline HTML for a duration: label shown, exact seconds on hover/tap (title + tabindex).
export function durationHtml(seconds, opts = {}) {
  const label = formatDuration(seconds, opts);
  if (label === "—") return "—";
  return `<span class="dur" tabindex="0" title="${exactSeconds(seconds)}" data-exact="${exactSeconds(seconds)}">${label}</span>`;
}
