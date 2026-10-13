// Each source's own data-through date (board_data meta.data_through: subway, gated_entries,
// cr_reliability, cr_boardings, survey). Set once from board_data; never typed in.
let DT = {};
export function setSourceDates(dt) { DT = dt && typeof dt === "object" ? { ...dt } : typeof dt === "string" ? { subway: dt } : {}; }
export function through(key) { const v = DT[key]; return typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null; }
const fmtDay = (iso) => new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
// "gate entries through Aug 31, 2026" (or "" when the build didn't say).
export function throughText(key, label) { const d = through(key); return d ? `${label} through ${fmtDay(d)}` : ""; }
export const GATE = () => throughText("gated_entries", "gate entries");
