// Charts panel: hand-rolled SVG, ink on parchment, one family. Every mark carries a hover summary
// (data-tip-s) and the exact row behind it (data-tip-d). Config: CHARTS in config.js. A missing
// table or column shows CHART_WAITING; nothing is estimated, smoothed or filled in.
import { CHARTS, CHART_WAITING, LINES, fallbackLineColor, COMMUTER_RAIL } from "./config.js";
import { TABLES } from "./queries.js";
import { formatDuration, exactSeconds } from "./duration.js";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const int = (v) => Math.round(v).toLocaleString("en-US");
const pct = (v, d = 1) => `${(v * 100).toFixed(d)}%`;
const day = (iso) => new Date(`${String(iso).slice(0, 10)}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" });
const DOW = [[1, "Mon", "Mondays"], [2, "Tue", "Tuesdays"], [3, "Wed", "Wednesdays"], [4, "Thu", "Thursdays"], [5, "Fri", "Fridays"], [6, "Sat", "Saturdays"], [0, "Sun", "Sundays"]];
export const dowName = (d) => (DOW.find((x) => x[0] === d) || [])[2] || "";
const tip = (s, d) => `data-tip-s="${esc(s)}" data-tip-d="${esc(d)}"`;
const lineLabel = (id) => (LINES.find((l) => l.line_id === id) || {}).label || id;
const lineName = (id) => (id === "Mattapan" ? "Mattapan Line" : `${lineLabel(id)} Line`);
const getPath = (o, p) => String(p || "").split(".").reduce((a, k) => (a == null ? a : a[k]), o);

// Single-hue ramp: parchment (#F8F2E4) -> sepia ink (#2B2118).
export function inkRamp(t) {
  const a = [248, 242, 228], b = [43, 33, 24], k = Math.max(0, Math.min(1, t)) ** 0.85;
  return `rgb(${a.map((x, i) => Math.round(x + (b[i] - x) * k)).join(",")})`;
}

// Shared-filter predicate for a chart table with the given column mapping (date, dayType, line).
const sq = (v) => `'${String(v).replace(/'/g, "''")}'`;
function whereOf(f, C) {
  const p = ["true"];
  if (C.date && f.dateFrom) p.push(`${C.date} >= ${sq(f.dateFrom)}::date`);
  if (C.date && f.dateTo) p.push(`${C.date} <= ${sq(f.dateTo)}::date`);
  if (C.dayType && f.dayType && f.dayType !== "all") p.push(`${C.dayType} = ${sq(f.dayType)}`);
  if (C.date && Number.isInteger(f.dow)) p.push(`dayofweek(${C.date}) = ${f.dow}`);
  if (C.line && f.lineIds && f.lineIds.length) p.push(`${C.line} in (${f.lineIds.map(sq).join(", ")})`);
  return p.join(" and ");
}

async function columnsOk(store, key, cols) {
  if (!key || !TABLES[key] || !store || !store.has(key)) return false;
  const have = await store.columns(key);
  return !!have && Object.values(cols).every((c) => have.includes(c));
}

// Planned work (the dbt build's is_planned_change, from his service_changes table). Label only: never changes a
// figure or the typical band. Missing column/table -> empty set, nothing drawn, no error.
// Keys: "<scope or route>|YYYY-MM-DD" and "<line_id>|YYYY-MM-DD".
const PLANNED_LABEL = "Planned work";
// the dbt build's service_changes rows for a flagged line-day, keyed like plannedSet; joined on date + line.
const CHANGE_WORD = { shuttle: "Shuttle buses", diversion: "Diversion", closure: "Station closed", suspension: "Suspended", slow_zone: "Slow zone", reduced_service: "Reduced service" };
async function plannedDetail(ctx) {
  const out = new Map();
  try {
    if (!ctx.store || !TABLES.serviceChanges) return out;
    if (ctx.store.ensure) await ctx.store.ensure("serviceChanges");
    if (!(await columnsOk(ctx.store, "serviceChanges", { a: "service_date", b: "route_id", c: "line_id", d: "change_type" }))) return out;
    const have = await ctx.store.columns("serviceChanges");
    const col = (c) => (have.includes(c) ? c : "null");
    const rows = await ctx.store.query(`select distinct service_date::varchar as d, route_id, line_id, change_type as t, ${col("from_station_name")} as f, ${col("to_station_name")} as e, ${have.includes("alert_header") ? "alert_header" : col("header_text")} as h, ${have.includes("display_effect_label") ? "display_effect_label" : "null"} as x
      from ${TABLES.serviceChanges}${have.includes("affects_line_day") ? " where affects_line_day = true" : ""}`);
    for (const r of rows || []) {
      const stops = r.f && r.e ? (r.f === r.e ? ` at ${r.f}` : `, ${r.f} to ${r.e}`) : "";
      // the dbt build's alert_header and display_effect_label (display_effect_detail is a raw code, never shown); both empty -> the change type alone.
      const h = String(r.h || "").trim(), x0 = String(r.x || "").trim(), x = /^[A-Z0-9_]+$/.test(x0) ? "" : x0; // never a raw code
      const tw = CHANGE_WORD[r.t] || String(r.t || "Change").replace(/_/g, " ");
      // the label already names the change (e.g. "Diversion timetable") -> drop the type word
      const head = x ? (x.toLowerCase().includes(tw.toLowerCase()) ? x : `${tw} · ${x}`) : tw;
      const txt = `${head}${stops}${h ? `: ${h}` : ""}`;
      for (const k of new Set([`${r.route_id}|${r.d}`, `${r.line_id}|${r.d}`])) { if (!out.has(k)) out.set(k, []); if (!out.get(k).includes(txt)) out.get(k).push(txt); }
    }
  } catch { /* optional */ }
  return out;
}
// "Planned work" plus the matching rows (plain words); the label alone when nothing matches.
// All subway row: name the flagged lines from the planned set ("Orange Line planned work"); none found -> plain label.
const PW_LINES = ["Red", "Orange", "Blue", "Green", "Mattapan"];
const sysPlannedLabel = (planned, d) => { const n = PW_LINES.filter((l) => planned.has(`${l}|${d}`)).map(lineName); if (!n.length) return PLANNED_LABEL; const list = n.length < 3 ? n.join(" and ") : `${n.slice(0, -1).join(", ")} and ${n[n.length - 1]}`; return `${list} planned work`; };
const plannedText = (detail, key, label = PLANNED_LABEL) => { const r = detail.get(key) || []; const full = r.filter((t) => t.includes(": ") || t.includes(" · ")); const use = (full.length ? full : r).slice(0, 2); return use.length ? `${label} · ${use.join("; ")}${(() => { const rest = r.filter((t) => !use.some((u) => u.startsWith(t))).length - use.length; return rest > 0 ? ` (+${rest} more)` : ""; })()}` : label; };
async function plannedSet(ctx) {
  const out = new Set();
  const add = (id, d) => { if (!id || !d) return; out.add(`${id}|${d}`); const l = lineOfRouteId(id); if (l) out.add(`${l}|${d}`); };
  const tries = [["lineDayMetrics", "scope_id"], ["lineDaily", "route_id"], ["serviceChanges", "route_id"], ["serviceChanges", "line_id"], ["serviceChanges", "scope_id"]];
  for (const [key, idc] of tries) {
    try {
      if (!ctx.store || !TABLES[key]) continue;
      if (ctx.store.ensure) await ctx.store.ensure(key);
      if (!(await columnsOk(ctx.store, key, { a: idc, b: "service_date", c: "is_planned_change" }))) continue;
      const rows = await ctx.store.query(`select distinct ${idc} as id, service_date::varchar as d from ${TABLES[key]} where is_planned_change = true`);
      for (const r of rows || []) add(r.id, r.d);
    } catch { /* optional */ }
  }
  return out;
}

// ---------------------------------------------------------------- 1. late runs by day (bound)
async function dailyChart(ctx) {
  const cfg = CHARTS.daily;
  const scope = ctx.scope(cfg.filters);
  if (!(await columnsOk(ctx.store, cfg.table, cfg.columns))) return waiting("daily", cfg.title, scope, `${cfg.table}: ${Object.values(cfg.columns).join(", ")}`);
  const thr = getPath(ctx.board, cfg.threshold);
  if (!isNum(thr)) return waiting("daily", cfg.title, scope, cfg.threshold);
  const f = ctx.xf && ctx.xf.kind === "date" ? { ...ctx.f, dateFrom: ctx.xf.prev.dateFrom, dateTo: ctx.xf.prev.dateTo } : ctx.f;
  const rows = await ctx.store.run("chartDaily", f);
  if (!rows || !rows.length) return section("daily", cfg.title, scope, `<p class="ch-wait">No runs for these filters.</p>`);
  const dates = [...new Set(rows.map((r) => r.d))].sort();
  const lines = LINES.map((l) => l.line_id).filter((id) => rows.some((r) => r.line_id === id));
  const share = (r) => (r.compared > 0 ? r.late / r.compared : null);
  // Typical band (the dbt build's line_day_metrics): p25-p75 of the same measure on the prior 28 same-day-type days,
  // per line and date (whole-line Green scope included). Lines without a scope there get no band; never combined.
  const band = new Map();
  if (ctx.store.has("lineDayMetrics")) {
    try {
      await ctx.store.ensure("lineDayMetrics");
      const br = await ctx.store.query(`select scope_id, service_date::varchar as d, typical_p25 as p25, typical_p75 as p75 from ${TABLES.lineDayMetrics} where measure = 'late_trip_share' and typical_p25 is not null and typical_p75 is not null`);
      for (const r of br || []) band.set(`${r.scope_id}|${r.d}`, r);
    } catch { /* no band */ }
  }
  // the dbt build's typical_is_thin / typical_days_n: fewer than 3 comparable days -> no band, no range, a note.
  // Columns missing -> nothing changes.
  const thin = new Map();
  if (await columnsOk(ctx.store, "lineDayMetrics", { a: "typical_is_thin", b: "typical_days_n" })) {
    try {
      const tr = await ctx.store.query(`select scope_id, service_date::varchar as d, typical_days_n as n from ${TABLES.lineDayMetrics} where measure = 'late_trip_share' and typical_is_thin = true`);
      for (const r of tr || []) { thin.set(`${r.scope_id}|${r.d}`, r.n); band.delete(`${r.scope_id}|${r.d}`); }
    } catch { /* keep current behaviour */ }
  }
  const planned = await plannedSet(ctx), pwDetail = planned.size ? await plannedDetail(ctx) : new Map();
  const visible = (r) => lines.includes(r.scope_id) && dates.includes(r.d);
  const max = Math.max(...rows.map(share).filter(isNum), ...[...band.values()].filter(visible).map((r) => r.p75).filter(isNum));
  const W = 300, H = 34, bw = W / dates.length, sel = ctx.xf && ctx.xf.kind === "date" ? ctx.xf.date : null;
  const thrText = formatDuration(thr);
  const multiples = lines.map((id) => {
    const by = new Map(rows.filter((r) => r.line_id === id).map((r) => [r.d, r]));
    const bandSvg = dates.map((d, i) => {
      const b = band.get(`${id}|${d}`);
      if (!b || !isNum(b.p25) || !isNum(b.p75) || !(max > 0)) return "";
      const y1 = H - (b.p75 / max) * (H - 2), y2 = H - (b.p25 / max) * (H - 2);
      return `<rect class="ch-band" x="${(i * bw).toFixed(2)}" y="${y1.toFixed(2)}" width="${bw.toFixed(2)}" height="${Math.max(0.4, y2 - y1).toFixed(2)}" aria-hidden="true"/>`;
    }).join("");
    const hasBand = bandSvg.length > 0;
    const bars = dates.map((d, i) => {
      const r = by.get(d), s = r && share(r);
      const b = band.get(`${id}|${d}`);
      const tk = `${id}|${d}`;
      const typ = thin.has(tk) ? ` · ${thinText(thin.get(tk))}` : b && isNum(b.p25) && isNum(b.p75) ? ` · typical ${pct(b.p25)}–${pct(b.p75)} (p25–p75)` : "";
      if (!isNum(s)) {
        // Planned line-day with no trips compared: still marked and explained, never given a bar.
        if (!planned.has(`${id}|${d}`)) return "";
        return `<rect class="ch-planned" x="${(i * bw).toFixed(2)}" y="0" width="${bw.toFixed(2)}" height="2" aria-hidden="true"/><rect class="ch-mark ch-pw-only" x="${(i * bw).toFixed(2)}" y="0" width="${bw.toFixed(2)}" height="${H}" style="fill:transparent" data-date="${esc(d)}" tabindex="-1"
        ${tip(`${day(d)}: ${lineName(id)}, no trips compared`, `${plannedText(pwDetail, `${id}|${d}`)}${r && isNum(r.compared) ? ` · ${int(r.compared)} trips compared` : ""}`)}/>`;
      }
      const h = max > 0 ? (s / max) * (H - 2) : 0;
      const on = sel === d, pw = planned.has(`${id}|${d}`);
      return `<rect class="ch-mark${on ? " is-on" : ""}${sel && !on ? " is-dim" : ""}" x="${(i * bw + 0.15).toFixed(2)}" y="${(H - h).toFixed(2)}" width="${Math.max(0.6, bw - 0.3).toFixed(2)}" height="${Math.max(0.6, h).toFixed(2)}"
        data-xf="date" data-date="${esc(d)}" tabindex="-1"
        ${tip(`${day(d)}: ${pct(s)} of ${lineName(id)} trips were more than ${thrText} late`, `${pw ? `${plannedText(pwDetail, `${id}|${d}`)} · ` : ""}${int(r.late)} of ${int(r.compared)} trips compared${typ} · ${DAYTYPE(r.day_type)} · click to filter to this day`)}/>${pw ? `<rect class="ch-planned" x="${(i * bw).toFixed(2)}" y="0" width="${bw.toFixed(2)}" height="2" aria-hidden="true"/>` : ""}`;
    }).join("");
    const col = ctx.lineColors[id] || fallbackLineColor(id) || "#6B5B48";
    const pwDays = dates.filter((d) => planned.has(`${id}|${d}`));
    const pwNote = pwDays.length ? `<span class="pw-tag" title="${esc(PLANNED_LABEL)}: ${esc(pwDays.map(day).join(", "))}">${esc(PLANNED_LABEL)} · ${esc(pwDays.length === 1 ? day(pwDays[0]) : `${pwDays.length} days`)}</span>` : "";
    return `<div class="ch-row"><span class="ch-lab"><i style="background:${esc(col)}"></i>${esc(lineLabel(id))}${pwNote}</span>
      <svg class="ch-svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="${esc(lineName(id))}, share of trips late by day${hasBand ? ", with the typical p25 to p75 band" : ""}">${bandSvg}${bars}<line class="ch-base" x1="0" x2="${W}" y1="${H - 0.3}" y2="${H - 0.3}"/></svg></div>`;
  }).join("");
  const short = (iso) => new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
  const axis = `<div class="ch-axis"><span>${esc(short(dates[0]))}</span><span>bar height: 0 – ${esc(pct(max))} of trips</span><span>${esc(short(dates[dates.length - 1]))}</span></div>`;
  return section("daily", cfg.title, scope, `<div class="ch-multi">${multiples}</div>${axis}`,
    `Share of trips more than ${esc(thrText)} late (late trips ÷ trips compared). Whole day: this table has no time of day or station.${band.size ? " Shaded band: the typical range (p25–p75 of the 28 earlier days of the same day type, from line_day_metrics)." : ""}`);
}

// One-line plate captions (scroll page); meaning only, never a number.
const CAPS = {
  daily: "Plate VIII. Each line's late runs, day by day.",
  daycmp: "Plate IX. One day against a typical day of the same kind.",
  dayworst: "Plate X. The worst stretches and stations of that one day.",
  heatmap: "Plate XI. Hour by hour: worse than usual, about usual, or better.",
  histogram: "Plate XII. How late the trips are, minute by minute.",
  donut: "Plate XIII. Each line's part of the subway's train delay.",
  cr: "Plate XIV. Commuter Rail, from the MBTA's own counts, on its own dates.",
  survey: "Plate XV. Who rides each line, from the 2025 passenger survey.",
};
const section = (id, title, scope, body, foot = "") => `
  <section class="ch" data-chart="${id}">
    <header class="ch-h"><h3 class="ch-t">${esc(title)}</h3>${scope ? `<p class="ch-k">${esc(scope)}</p>` : ""}</header>
    ${body}${foot ? `<p class="ch-n">${foot}</p>` : ""}
    ${CAPS[id] ? `<p class="plate-cap">${esc(CAPS[id])}</p>` : ""}
  </section>`;
const waiting = (id, title, scope, need) => section(id, title, scope, `<p class="ch-wait" title="${esc(need)}">${esc(CHART_WAITING)}</p>`);

// Route scopes in dbt files (line_day_metrics, heatmaps, histogram): the subway routes of the picked lines.
const ROUTE_NAMES = { Red: "Red Line", Mattapan: "Mattapan Line", Orange: "Orange Line", Blue: "Blue Line",
  "Green-B": "Green Line B", "Green-C": "Green Line C", "Green-D": "Green Line D", "Green-E": "Green Line E", system: "All subway lines" };
const lineOfRouteId = (id) => (LINES.find((l) => l.route_ids.includes(id)) || {}).line_id || "";
const routeName = (id) => ROUTE_NAMES[id] || id;
const DAYTYPE = (t) => ({ weekday: "weekday", saturday: "Saturday", sunday: "Sunday", holiday: "holiday" })[String(t || "").toLowerCase()] || (t || "");
const routesOf = (lineIds) => LINES.filter((l) => !lineIds || !lineIds.length || lineIds.includes(l.line_id)).flatMap((l) => l.route_ids);
const allLines = (f) => !f.lineIds || !f.lineIds.length || f.lineIds.length === LINES.length;
const routeColor = (ctx, id) => { const l = LINES.find((x) => x.route_ids.includes(id)); return (l && (ctx.lineColors[l.line_id] || l.fallbackColor)) || "#2B2118"; };
// The one day these plates describe: a single picked date, else the latest service date (meta.service_date).
const focusDay = (ctx) => (ctx.f.dateFrom && ctx.f.dateFrom === ctx.f.dateTo ? ctx.f.dateFrom : ctx.serviceDate);
const dayY = (iso) => new Date(`${String(iso).slice(0, 10)}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
const signed = (v, d = 1, unit = "") => `${v > 0 ? "+" : v < 0 ? "\u2212" : ""}${Math.abs(v).toFixed(d)}${unit}`;
const pp = (v) => `${signed(v * 100, 1)} points`;
async function hasCols(ctx, key, cols) { if (ctx.store && ctx.store.ensure) await ctx.store.ensure(key); return columnsOk(ctx.store, key, Object.fromEntries(cols.map((c) => [c, c]))); }

// ---------------------------------------------------------------- 2. one day vs typical (line_day_metrics)
const DAY_MEASURES = [
  { m: "late_trip_share", label: "Trips late", fmt: (v) => pct(v), diff: pp, what: "of trips were late" },
  { m: "long_gap_share", label: "Long gaps", fmt: (v) => pct(v), diff: pp, what: "of departures came after a long gap" },
  { m: "train_delay_positive_per_run_seconds", label: "Delay per run", fmt: (v) => `${v.toFixed(1)} s`, diff: (v) => signed(v, 1, " s"), what: "of late time per run between two stops" },
];
const thinText = (n) => `Not enough comparable days (${isNum(n) ? int(n) : "?"})`;
async function dayCompareChart(ctx) {
  const title = "One day against a typical day";
  const d = focusDay(ctx);
  const need = ["scope_id", "service_date", "measure", "value", "numerator", "denominator", "typical_median", "typical_p25", "typical_p75", "typical_days", "typical_first_date", "typical_last_date", "day_type", "diff_vs_median"];
  if (!d || !(await hasCols(ctx, "lineDayMetrics", need))) return waiting("daycmp", title, "", "line_day_metrics");
  const scopes = ["system", ...routesOf(ctx.f.lineIds)];
  const hasThin = await columnsOk(ctx.store, "lineDayMetrics", { a: "typical_is_thin", b: "typical_days_n" });
  const rows = await ctx.store.query(`select scope_id, measure, value, numerator, denominator, typical_median, typical_p25, typical_p75, typical_days,${hasThin ? " typical_is_thin as thin, typical_days_n as thin_n," : ""}
      typical_first_date::varchar as tf, typical_last_date::varchar as tl, day_type, diff_vs_median
    from ${TABLES.lineDayMetrics} where service_date = ${sq(d)}::date and scope_id in (${scopes.map(sq).join(", ")})
      and measure in (${DAY_MEASURES.map((x) => sq(x.m)).join(", ")})`);
  if (!rows || !rows.length) return section("daycmp", title, day(d), `<p class="ch-wait">No recorded runs on this day.</p>`);
  const planned = await plannedSet(ctx), pwDetail = planned.size ? await plannedDetail(ctx) : new Map();
  const get = (s, m) => rows.find((r) => r.scope_id === s && r.measure === m);
  const sys = get("system", "late_trip_share");
  const dt = sys ? sys.day_type : rows[0].day_type;
  const head = `<tr><th></th>${DAY_MEASURES.map((x) => `<th>${esc(x.label)}</th>`).join("")}</tr>`;
  const body = scopes.filter((s) => rows.some((r) => r.scope_id === s)).map((s) => {
    const cells = DAY_MEASURES.map((x) => {
      const r = get(s, x.m);
      if (!r || !isNum(r.value)) return `<td class="dim">—</td>`;
      const isThin = r.thin === true;
      const hasTyp = !isThin && isNum(r.typical_median);
      const above = hasTyp && isNum(r.typical_p75) && r.value > r.typical_p75, below = hasTyp && isNum(r.typical_p25) && r.value < r.typical_p25;
      const word = isThin ? thinText(r.thin_n).toLowerCase() : !hasTyp ? "no typical day to compare" : above ? "worse than usual" : below ? "better than usual" : "within the usual range";
      const nd = isNum(r.numerator) && isNum(r.denominator) ? `${int(r.numerator)} of ${int(r.denominator)} · ` : "";
      const typ = isThin ? thinText(r.thin_n) : hasTyp ? `typical ${x.fmt(r.typical_median)} (middle half ${x.fmt(r.typical_p25)}–${x.fmt(r.typical_p75)}, ${r.typical_days} earlier ${r.day_type}s ${day(r.tf)} – ${day(r.tl)}) · difference ${x.diff(r.diff_vs_median)}` : "no typical value";
      return `<td class="dc${above ? " is-worse" : below ? " is-better" : ""}" ${tip(`${routeName(s)}, ${day(d)}: ${x.fmt(r.value)} ${x.what}, ${word}`, `${planned.has(`${s}|${d}`) ? `${plannedText(pwDetail, `${s}|${d}`, s === "system" ? sysPlannedLabel(planned, d) : PLANNED_LABEL)} · ` : ""}${nd}${typ}`)}>
        <span class="dc-v">${esc(x.fmt(r.value))}${x.m !== "train_delay_positive_per_run_seconds" && isNum(r.numerator) && isNum(r.denominator) ? `<span class="dc-n">, ${esc(int(r.numerator))} of ${esc(int(r.denominator))}</span>` : ""}</span>${hasTyp ? `<span class="dc-t">typical ${esc(x.fmt(r.typical_median))}</span>` : isThin ? `<span class="dc-t dc-thin">${esc(thinText(r.thin_n))}</span>` : ""}</td>`;
    }).join("");
    const lab = s === "system" ? "All subway" : routeName(s).replace(/ Line/, "");
    return `<tr${s === "system" ? ' class="dc-sys"' : ""}><th${s === "system" ? "" : ` class="xf-line" data-line="${esc(lineOfRouteId(s))}" tabindex="0" role="button" aria-label="Filter to ${esc(routeName(s))}"`}><i style="background:${esc(s === "system" ? "#2B2118" : routeColor(ctx, s))}"></i>${esc(lab)}${planned.has(`${s}|${d}`) ? `<span class="pw-sep">, </span> <span class="pw-tag">${esc(s === "system" ? sysPlannedLabel(planned, d) : PLANNED_LABEL)}</span>` : ""}</th>${cells}</tr>`;
  }).join("");
  return section("daycmp", title, `${day(d)} · ${DAYTYPE(dt)} · pick one date in the strip to change the day`,
    `<div class="ch-tablewrap"><table class="ch-table dc-table">${head}${body}</table></div>`,
    `${esc(getPath(ctx.board, "latest_day.typical_rule") || "")} Shaded: above the typical 75th percentile (worse than usual); outlined: below the 25th (better). Late = more than ${esc(isNum(getPath(ctx.board, "meta.thresholds.late_trip_seconds")) ? formatDuration(getPath(ctx.board, "meta.thresholds.late_trip_seconds")) : "?")}; long gap = more than ${esc(getPath(ctx.board, "meta.thresholds.long_gap_ratio") ?? "?")}× the scheduled gap.`);
}

// ---------------------------------------------------------------- 3. worst of the day (day_worst_segments / _stations)
async function dayWorstChart(ctx) {
  const title = "The worst of that day";
  const d = focusDay(ctx);
  const okS = await hasCols(ctx, "dayWorstSegments", ["scope_id", "service_date", "day_rank", "segment_name", "positive_excess_seconds", "runs_compared", "typical_median_positive_seconds", "diff_vs_median_seconds"]);
  const okT = await hasCols(ctx, "dayWorstStations", ["scope_id", "service_date", "day_rank", "station_name", "long_gaps", "headway_observations", "long_gap_share", "typical_median_long_gaps"]);
  if (!d || !okS || !okT) return waiting("dayworst", title, "", "day_worst_segments, day_worst_stations");
  const scopes = routesOf(ctx.f.lineIds);
  const segs = await ctx.store.query(`select * exclude (service_date), service_date::varchar as d from ${TABLES.dayWorstSegments} where service_date = ${sq(d)}::date and scope_id in (${scopes.map(sq).join(", ")}) order by scope_id, day_rank`);
  const sts = await ctx.store.query(`select * exclude (service_date), service_date::varchar as d from ${TABLES.dayWorstStations} where service_date = ${sq(d)}::date and scope_id in (${scopes.map(sq).join(", ")}) order by scope_id, day_rank`);
  if ((!segs || !segs.length) && (!sts || !sts.length)) return section("dayworst", title, day(d), `<p class="ch-wait">No recorded runs on this day.</p>`);
  const blocks = scopes.filter((s) => (segs || []).some((r) => r.scope_id === s) || (sts || []).some((r) => r.scope_id === s)).map((s) => {
    const sg = (segs || []).filter((r) => r.scope_id === s).map((r) => `<li ${tip(`${r.segment_name}: ${formatDuration(r.positive_excess_seconds)} of train delay on ${day(d)}`,
      `${int(r.runs_compared)} runs · exact ${exactSeconds(r.positive_excess_seconds)}${isNum(r.typical_median_positive_seconds) ? ` · typical ${formatDuration(r.typical_median_positive_seconds)} (median of ${r.typical_days} earlier days) · difference ${formatDuration(r.diff_vs_median_seconds, { signed: true })}` : ""}`)}>
      <span class="dw-n">${r.day_rank}</span>${esc(r.segment_name)} <span class="dw-v">${esc(formatDuration(r.positive_excess_seconds))}</span></li>`).join("");
    const st = (sts || []).filter((r) => r.scope_id === s).map((r) => `<li ${tip(`${r.station_name}: ${int(r.long_gaps)} departures after a long gap on ${day(d)}`,
      `${int(r.long_gaps)} of ${int(r.headway_observations)} departures (${pct(r.long_gap_share)})${isNum(r.typical_median_long_gaps) ? ` · typical ${int(r.typical_median_long_gaps)} (median of ${r.typical_days} earlier days)` : ""}`)}>
      <span class="dw-n">${r.day_rank}</span><button type="button" class="xf-st" data-station="${esc(r.station_id)}">${esc(r.station_name)}</button> <span class="dw-v">${esc(int(r.long_gaps))} long gaps</span></li>`).join("");
    return `<div class="dw"><h4 class="dw-h xf-line" data-line="${esc(lineOfRouteId(s))}" tabindex="0" role="button" aria-label="Filter to ${esc(routeName(s))}"><i style="background:${esc(routeColor(ctx, s))}"></i>${esc(routeName(s))}</h4>
      <p class="dw-k">Stretches, most train delay</p><ol class="dw-l">${sg || "<li class='dim'>—</li>"}</ol>
      <p class="dw-k">Stations, most long gaps</p><ol class="dw-l">${st || "<li class='dim'>—</li>"}</ol></div>`;
  }).join("");
  return section("dayworst", title, `${day(d)} · top 3 per line`, `<div class="dw-grid">${blocks}</div>`,
    esc(`${getPath(ctx.board, "latest_day.worst_segments_rule") || ""} ${getPath(ctx.board, "latest_day.worst_stations_rule") || ""}`));
}

// ---------------------------------------------------------------- 4. hourly heatmap (line_hour_heatmap / per-line station heatmaps)
const RATE = { worse: ["worse", "Worse than usual"], about: ["about", "About usual"], better: ["better", "Better than usual"], not_enough_data: ["none", "Not rated"] };
const HEAT_MEASURES = [
  { k: "delay", label: "Delay per run", col: "usual_train_delay_per_run", v: "train_delay_positive_per_run_seconds", p: "train_delay_positive_per_run_seconds", fmt: (v) => `${v.toFixed(1)} s`, n: "runs_compared", nl: "runs" },
  { k: "late", label: "Trips late", col: "usual_late_trip_share", v: "late_trip_share", p: "late_trip_share", fmt: (v) => pct(v), n: "trips_compared", nl: "trips", lineOnly: true },
  { k: "gaps", label: "Long gaps", col: "usual_long_gap_share", v: "long_gap_share", p: "long_gap_share", fmt: (v) => pct(v), n: "headway_observations", nl: "departures" },
];
async function heatChart(ctx) {
  const title = "Hour by hour, against usual";
  const d = focusDay(ctx);
  const station = ctx.f.stationId;
  let M = HEAT_MEASURES.find((x) => x.k === ctx.heatMeasure) || HEAT_MEASURES[0];
  if (station && M.lineOnly) M = HEAT_MEASURES[0];
  const key = "lineHourHeatmap";
  // Station view: only the per-line files (charts.station_heatmap_files_by_line) for the lines serving
  // that station. There is no combined file; a line without its own file is "not available".
  const byLine = getPath(ctx.board, "charts.station_heatmap_files_by_line");
  let from = TABLES[key], missingLines = [];
  if (station) {
    const all = ctx.stationLines ? ctx.stationLines(station) : [];
    const map = byLine && typeof byLine === "object" ? byLine : {};
    const lines = all.filter((l) => typeof map[l] === "string");
    missingLines = all.filter((l) => typeof map[l] !== "string");
    const views = ctx.store.ensureFile ? (await Promise.all(lines.map((l) => ctx.store.ensureFile(map[l])))).filter(Boolean) : [];
    if (!views.length) return section("heatmap", title, ctx.stationName ? ctx.stationName(station) : "", `<p class="ch-wait">Hour-by-hour ratings are not available for this station.</p>`);
    from = `(${views.map((v) => `select * from ${v}`).join(" union all by name ")})`;
  } else if (!d || !(await hasCols(ctx, key, ["service_date", "service_hour", "typical_days", M.col, M.v, M.n, `typical_median_${M.p}`, `typical_p25_${M.p}`, `typical_p75_${M.p}`]))) return waiting("heatmap", title, "", key);
  if (!d) return waiting("heatmap", title, "", key);
  const scopes = station ? null : ["system", ...routesOf(ctx.f.lineIds)];
  const rowKey = station ? "line_id" : "scope_id";
  const rows = await ctx.store.query(`select ${rowKey} as rk, service_hour::int as h, ${M.col} as rating, ${M.v} as v, ${M.n} as n,
      typical_median_${M.p} as tm, typical_p25_${M.p} as t25, typical_p75_${M.p} as t75, typical_days_${M.p} as td
    from ${from} where service_date = ${sq(d)}::date ${station ? `and station_id = ${sq(station)}` : `and scope_id in (${scopes.map(sq).join(", ")})`}`);
  const tabs = `<div class="ch-tabs">${HEAT_MEASURES.filter((x) => !(station && x.lineOnly)).map((x) => `<button type="button" data-heat="${x.k}" aria-pressed="${x.k === M.k}">${esc(x.label)}</button>`).join("")}</div>`;
  if (!rows || !rows.length) return section("heatmap", title, day(d), `${tabs}<p class="ch-wait">No recorded runs for this day${station ? " at this station" : ""}.</p>`);
  const hours = [...new Set(rows.map((r) => r.h))].sort((a, b) => a - b);
  const keys = station ? [...new Set(rows.map((r) => r.rk))] : scopes.filter((s) => rows.some((r) => r.rk === s));
  const LW = 96, CW = 22, CH = 18, W = LW + CW * hours.length, H = 18 + CH * keys.length;
  const cell = new Map(rows.map((r) => [`${r.rk}|${r.h}`, r]));
  const hh = (h) => `${String(h % 24).padStart(2, "0")}:00`;
  let svg = hours.map((h, i) => (i % 2 === 0 ? `<text class="ch-ax" x="${LW + i * CW + CW / 2}" y="12" text-anchor="middle">${h % 24}</text>` : "")).join("");
  keys.forEach((k, j) => {
    const y = 18 + j * CH;
    const lab = station ? (lineLabel(k) || k) : k === "system" ? "All subway" : routeName(k).replace(/ Line/, "");
    svg += `<text class="ch-ax" x="${LW - 6}" y="${y + CH / 2 + 4}" text-anchor="end">${esc(lab)}</text>`;
    hours.forEach((h, i) => {
      const r = cell.get(`${k}|${h}`), x = LW + i * CW;
      if (!r) return;
      const [cls, word] = RATE[r.rating] || RATE.not_enough_data;
      const name = station ? `${ctx.stationName(station)} (${lab})` : (k === "system" ? "All subway lines" : routeName(k));
      const val = isNum(r.v) ? M.fmt(r.v) : "—";
      const det = `${isNum(r.n) ? `${int(r.n)} ${M.nl}` : ""}${isNum(r.tm) ? ` · typical ${M.fmt(r.tm)}, usual range ${isNum(r.t25) ? M.fmt(r.t25) : "—"}–${isNum(r.t75) ? M.fmt(r.t75) : "—"} (${r.td} earlier days)` : " · no typical value"}`;
      const hsel = ctx.xf && ctx.xf.kind === "hour" ? ctx.xf.hour : null;
      svg += `<rect class="ch-cell rate-${cls}${hsel === h ? " is-on" : hsel != null ? " is-dim" : ""}" data-xf="hour" data-hour="${h}" x="${x + 1}" y="${y + 1}" width="${CW - 2}" height="${CH - 2}" ${tip(`${name}, ${day(d)} ${hh(h)}–${hh(h + 1)}: ${M.label.toLowerCase()} ${val}, ${word.toLowerCase()}`, det)}/>`;
    });
  });
  const allNone = rows.every((r) => !RATE[r.rating] || RATE[r.rating] === RATE.not_enough_data);
  const naCap = missingLines.length ? `<p class="ch-wait">Not available for ${esc(missingLines.map((l) => lineLabel(l) || l).join(", "))}.</p>` : "";
  const noneCap = station && allNone ? `<p class="ch-wait ch-none-cap">Too few runs per hour to rate a single station.</p>` : "";
  const legend = `<div class="ch-legend ch-rates">${Object.values(RATE).map(([c, w]) => `<span><i class="rate-${c}"></i>${esc(w)}</span>`).join("")}</div>`;
  return section("heatmap", title, `${day(d)}${station ? ` · ${ctx.stationName(station)}` : ""} · ${M.label.toLowerCase()}`,
    `${tabs}<div class="ch-tablewrap"><svg class="ch-svg ch-heat" viewBox="0 0 ${W} ${H}" style="min-width:${Math.round(W * 1.1)}px" role="img" aria-label="Hour by hour rating against usual">${svg}</svg></div>${noneCap}${naCap}${legend}`,
    `${esc(getPath(ctx.board, "meta.thresholds.usual_rule") || "")} Hours after midnight belong to the previous service day.${station ? "" : " Pick a station on the map to see its hours."}`);
}

// ---------------------------------------------------------------- 5. histogram (delay_histogram, kind = trip)
async function histChart(ctx) {
  const title = "How late the trips are, minute by minute";
  const scope = ctx.scope(["dates", "dayType", "lines", "dow"]);
  if (!(await hasCols(ctx, "delayHistogram", ["kind", "scope_id", "service_date", "day_type", "bin_minute", "bin_label", "is_open_bin", "observations"]))) return waiting("histogram", title, scope, "delay_histogram");
  const thr = getPath(ctx.board, "meta.thresholds.late_trip_seconds");
  const f = ctx.f;
  const scopes = allLines(f) ? ["system"] : routesOf(f.lineIds);
  const rows = await ctx.store.query(`select bin_minute::int as bin, any_value(bin_label) as label, bool_or(is_open_bin) as open, sum(observations)::double as runs
    from ${TABLES.delayHistogram} where kind = 'trip' and scope_id in (${scopes.map(sq).join(", ")}) and ${whereOf({ ...f, lineIds: [] }, { date: "service_date", dayType: "day_type" })}
    group by 1 order by 1`);
  if (!rows || !rows.length) return section("histogram", title, scope, `<p class="ch-wait">No trips for these filters.</p>`);
  const total = rows.reduce((a, r) => a + r.runs, 0);
  const lo = Math.min(...rows.map((r) => r.bin)), hi = Math.max(...rows.map((r) => r.bin));
  const n = hi - lo + 1, W = 300, H = 90, bw = W / n, max = Math.max(...rows.map((r) => r.runs));
  const sel = ctx.xf && ctx.xf.kind === "bin" ? ctx.xf.bin : null;
  let svg = rows.map((r) => {
    const h = (r.runs / max) * (H - 4), x = (r.bin - lo) * bw, on = sel === r.bin;
    return `<rect class="ch-mark${r.open ? " is-open" : ""}${on ? " is-on" : ""}${sel != null && !on ? " is-dim" : ""}" x="${(x + 0.3).toFixed(2)}" y="${(H - h).toFixed(2)}" width="${Math.max(0.6, bw - 0.6).toFixed(2)}" height="${Math.max(0.6, h).toFixed(2)}"
      data-xf="bin" data-bin="${r.bin}" ${tip(`${r.label} ${r.bin < 0 || /under/.test(r.label) ? "(early)" : "vs schedule"}: ${int(r.runs)} trips`, `${pct(r.runs / total, 2)} of ${int(total)} trips shown${r.open ? " · open-ended bin" : ""}`)}/>`;
  }).join("");
  if (isNum(thr)) { const x = ((thr / 60) - lo) * bw; svg += `<line class="ch-thr" x1="${x.toFixed(2)}" x2="${x.toFixed(2)}" y1="0" y2="${H}"/>`; }
  const labLo = rows[0].label, labHi = rows[rows.length - 1].label;
  return section("histogram", title, `${scope}${scopes[0] === "system" ? "" : ` · ${scopes.map(routeName).join(", ")}`}`, `<svg class="ch-svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Trips by minutes over schedule">${svg}</svg>
    <div class="ch-axis"><span>${esc(labLo)}</span>${isNum(thr) ? `<span>dashed line: ${esc(formatDuration(thr))} (late)</span>` : ""}<span>${esc(labHi)}</span></div>`,
    "Each bar is one minute of whole-trip time over schedule; the bars at each end are open-ended. Negative = faster than scheduled.");
}

// ---------------------------------------------------------------- 6. donut (train_delay_by_line, period_kind = date)
async function donutChart(ctx) {
  const title = "Each line's share of train delay";
  const scope = ctx.scope(["dates", "dayType", "dow"]);
  if (!(await hasCols(ctx, "trainDelayByLine", ["period_kind", "service_date", "route_id", "display_name", "positive_excess_seconds", "system_positive_excess_seconds"]))) return waiting("donut", title, scope, "train_delay_by_line");
  const f = { ...ctx.f, lineIds: [] };
  // day_type comes from train_delay_daily (same service dates).
  const w = whereOf(f, { date: "t.service_date", dayType: "d.day_type" });
  const slices = await ctx.store.query(`select t.route_id, any_value(t.display_name) as name, sum(t.positive_excess_seconds)::double as v, count(*)::int as days
    from ${TABLES.trainDelayByLine} t join ${TABLES.trainDelayDaily} d on d.service_date = t.service_date
    where t.period_kind = 'date' and ${w} group by 1 order by 3 desc`);
  const tot = await ctx.store.query(`select sum(s)::double as v, count(*)::int as days from (select t.service_date, any_value(t.system_positive_excess_seconds) as s
    from ${TABLES.trainDelayByLine} t join ${TABLES.trainDelayDaily} d on d.service_date = t.service_date where t.period_kind = 'date' and ${w} group by 1)`);
  const total = tot && tot[0] && tot[0].v, days = (tot && tot[0] && tot[0].days) || 0;
  const sum = (slices || []).reduce((a, r) => a + (r.v || 0), 0);
  if (!slices || !slices.length || !isNum(total) || total <= 0) return section("donut", title, scope, `<p class="ch-wait">No train delay for these filters.</p>`);
  if (Math.abs(sum - total) > 0.5 * Math.max(1, days)) return section("donut", title, scope, `<p class="ch-err">The line totals don't add up to the system total, so the chart isn't drawn.</p>`, `Lines ${esc(exactSeconds(sum))} · system ${esc(exactSeconds(total))}`);
  let a0 = -Math.PI / 2, svg = "";
  const R = 44, r0 = 27;
  const p = (a, r) => `${(r * Math.cos(a)).toFixed(2)} ${(r * Math.sin(a)).toFixed(2)}`;
  slices.forEach((s, i) => {
    const a1 = a0 + (s.v / total) * Math.PI * 2, big = a1 - a0 > Math.PI ? 1 : 0;
    const col = routeColor(ctx, s.route_id);
    svg += `<path class="ch-slice xf-line" data-line="${esc(lineOfRouteId(s.route_id))}" tabindex="0" role="button" aria-label="${esc(s.name)}: filter to this line" d="M${p(a0, R)} A${R} ${R} 0 ${big} 1 ${p(a1, R)} L${p(a1, r0)} A${r0} ${r0} 0 ${big} 0 ${p(a0, r0)} Z" fill="${esc(col)}" style="opacity:${s.route_id.startsWith("Green-") ? [1, 0.82, 0.64, 0.5][["Green-B", "Green-C", "Green-D", "Green-E"].indexOf(s.route_id)] : 1}"
      ${tip(`${s.name}: ${pct(s.v / total)} of the subway's train delay`, `${formatDuration(s.v)} of ${formatDuration(total)} late time over ${days} ${days === 1 ? "day" : "days"} · exact ${exactSeconds(s.v)}`)}/>`;
    a0 = a1;
  });
  const key = `<ul class="dn-key">${slices.map((s) => `<li><i style="background:${esc(routeColor(ctx, s.route_id))}"></i>${esc(s.name)} <span class="dn-v">${esc(pct(s.v / total))}</span></li>`).join("")}</ul>`;
  return section("donut", title, scope, `<div class="dn-wrap"><svg class="ch-svg ch-donut" viewBox="-50 -50 100 100" role="img" aria-label="Each line's share of train delay">${svg}</svg>${key}</div>`,
    "Late time only, summed over every run between two stops. Not adjusted for trips run: lines that run more trains or longer routes score higher. Commuter Rail is not part of train delay.");
}

// ---------------------------------------------------------------- 7. Commuter Rail (cr_monthly; own dates)
async function crChart(ctx) {
  const title = "Commuter Rail on time";
  if (!(await hasCols(ctx, "crMonthly", ["scope_id", "month_start_date", "on_time_trips", "counted_trips", "on_time_share", "cancelled_trips", "is_complete_reliability_month", "estimated_boardings_sum", "is_complete_boardings_month", "reliability_days", "boardings_days"]))) return waiting("cr", title, "Own dates · not affected by the filters", "cr_monthly");
  const cr = (ctx.board && ctx.board.commuter_rail) || {};
  const months = await ctx.store.query(`select month_start_date::varchar as m, on_time_trips, counted_trips, on_time_share, cancelled_trips, reliability_days,
      estimated_boardings_sum, boardings_days, is_complete_reliability_month as rc, is_complete_boardings_month as bc
    from ${TABLES.crMonthly} where scope_id = 'commuter_rail' and month_start_date > (select max(month_start_date) from ${TABLES.crMonthly} where scope_id = 'commuter_rail') - interval 12 month order by 1`);
  if (!months || !months.length) return waiting("cr", title, "", "no rows");
  const mon = (iso) => new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", year: "numeric", timeZone: "UTC" });
  const relM = [...months].reverse().find((r) => r.rc && isNum(r.on_time_share));
  const boardM = [...months].reverse().find((r) => r.bc && isNum(r.estimated_boardings_sum));
  const W = 300, H = 70, bw = W / months.length;
  const vals = months.map((r) => r.on_time_share).filter(isNum), lo = Math.min(...vals), hi = Math.max(...vals);
  const svg = months.map((r, i) => {
    if (!isNum(r.on_time_share)) return "";
    const h = hi > lo ? 8 + ((r.on_time_share - lo) / (hi - lo)) * (H - 12) : H / 2;
    return `<rect class="ch-mark cr-bar${r.rc ? "" : " is-open"}" x="${(i * bw + 1).toFixed(2)}" y="${(H - h).toFixed(2)}" width="${(bw - 2).toFixed(2)}" height="${h.toFixed(2)}" style="fill:${COMMUTER_RAIL.FALLBACK_COLOR}"
      ${tip(`${mon(r.m)}: ${pct(r.on_time_share, 1)} of Commuter Rail trips on time`, `${int(r.on_time_trips)} of ${int(r.counted_trips)} trips counted · ${int(r.cancelled_trips)} cancelled · ${r.reliability_days} days reported${r.rc ? "" : " · month not complete"}${isNum(r.estimated_boardings_sum) ? ` · ${int(r.estimated_boardings_sum)} boardings (MBTA estimate, ${r.boardings_days} days)` : ""}`)}/>`;
  }).join("");
  const facts = [];
  if (relM) facts.push(`<p class="cr-fact"><span class="num">${esc(pct(relM.on_time_share, 1))}</span> of trips on time in ${esc(mon(relM.m))}: ${esc(int(relM.on_time_trips))} of ${esc(int(relM.counted_trips))}, with ${esc(int(relM.cancelled_trips))} cancelled.</p>`);
  if (boardM) facts.push(`<p class="cr-fact"><span class="num">${esc(int(boardM.estimated_boardings_sum))}</span> boardings in ${esc(mon(boardM.m))}, the MBTA's own estimate from scaled conductor counts.</p>`);
  const rr = cr.reliability_date_range || {}, br = cr.boardings_date_range || {};
  // Each source's own data-through date (meta.data_through), never the subway date.
  const dt = getPath(ctx.board, "meta.data_through") || {};
  const relT = typeof dt.cr_reliability === "string" ? dt.cr_reliability : rr.last, brdT = typeof dt.cr_boardings === "string" ? dt.cr_boardings : br.last;
  return section("cr", title, `On-time data ${rr.first ? dayY(rr.first) : "—"} through ${relT ? dayY(relT) : "—"} · boardings ${br.first ? dayY(br.first) : "—"} through ${brdT ? dayY(brdT) : "—"} · last 12 months shown · not affected by the filters`,
    `${facts.join("")}<svg class="ch-svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Commuter Rail on-time share by month">${svg}</svg>
     <div class="ch-axis"><span>${esc(mon(months[0].m))}</span><span>bar height: ${esc(pct(lo, 1))} – ${esc(pct(hi, 1))} on time</span><span>${esc(mon(months[months.length - 1].m))}</span></div>`,
    esc(`${cr.on_time_rule || ""} Commuter Rail is not part of train delay or the top 10.`));
}

// ---------------------------------------------------------------- 8. survey (survey_lines; own dates)
const SURVEY_TOPICS = [["Income|Title VI Low-Income", "Low income"], ["Race and Ethnicity|Title VI Minority", "Minority"], ["Other Demographics|Age", "Age"],
  ["Trip Purpose and Frequency|Trip Purpose", "Trip purpose"], ["Vehicles|Usable Cars", "Cars at home"], ["Fares|Reduced Fares", "Reduced fares"]];
async function surveyChart(ctx) {
  const title = "Who rides: the 2025 passenger survey";
  const sv = getPath(ctx.board, "meta.data_through.survey");
  const own = `${typeof sv === "string" ? sv : "2025 survey"} · not affected by the filters`;
  if (!(await hasCols(ctx, "surveyLines", ["scope_id", "mode", "survey_line_name", "measure_group", "measure", "category", "weighted_share", "respondents", "margin_of_error"]))) return waiting("survey", title, own, "survey_lines");
  const topic = SURVEY_TOPICS.find((t) => t[0] === ctx.surveyTopic) || SURVEY_TOPICS[0];
  const [g, m] = topic[0].split("|");
  const rows = await ctx.store.query(`select scope_id, mode, category, weighted_share as share, respondents as n, margin_of_error as moe
    from ${TABLES.surveyLines} where measure_group = ${sq(g)} and measure = ${sq(m)} order by scope_id`);
  const tabs = `<div class="ch-tabs">${SURVEY_TOPICS.map(([k, l]) => `<button type="button" data-survey="${esc(k)}" aria-pressed="${k === topic[0]}">${esc(l)}</button>`).join("")}</div>`;
  if (!rows || !rows.length) return section("survey", title, own, `${tabs}<p class="ch-wait">${esc(CHART_WAITING)}</p>`);
  const cats = [...new Set(rows.map((r) => r.category))];
  const order = ["Red", "Mattapan", "Orange", "Green", "Blue", "commuter_rail"];
  const labOf = (s) => (s === "commuter_rail" ? "Commuter Rail" : lineLabel(s));
  const colOf = (s) => (s === "commuter_rail" ? COMMUTER_RAIL.FALLBACK_COLOR : ctx.lineColors[s] || fallbackLineColor(s) || "#2B2118");
  const bars = order.filter((s) => rows.some((r) => r.scope_id === s)).map((s) => {
    let x = 0;
    const segs = cats.map((c, i) => {
      const r = rows.find((q) => q.scope_id === s && q.category === c);
      if (!r || !isNum(r.share)) return "";
      const w = r.share * 100, out = `<rect x="${x.toFixed(2)}" y="0" width="${w.toFixed(2)}" height="10" fill="${inkRamp(cats.length > 1 ? 0.12 + 0.8 * (i / (cats.length - 1)) : 0.5)}" class="ch-seg"
        ${tip(`${labOf(s)} riders: ${pct(r.share)} answered "${c}"`, `Margin of error ±${isNum(r.moe) ? pct(r.moe, 2) : "—"} (the survey states no confidence level) · ${isNum(r.n) ? int(r.n) : "—"} respondents (n) · weighted share`)}/>`;
      x += w;
      return out;
    }).join("");
    const n = rows.find((q) => q.scope_id === s && isNum(q.n));
    return `<div class="ch-row"><span class="ch-lab"><i style="background:${esc(colOf(s))}"></i>${esc(labOf(s))}</span><svg class="ch-svg" viewBox="0 0 100 10" preserveAspectRatio="none" role="img" aria-label="${esc(labOf(s))}: answers by share of riders">${segs}</svg><span class="ch-n-r">n ${n ? esc(int(n.n)) : "—"}</span></div>`;
  }).join("");
  const key = `<div class="ch-key">${cats.map((c, i) => `<span><i style="background:${inkRamp(cats.length > 1 ? 0.12 + 0.8 * (i / (cats.length - 1)) : 0.5)}"></i>${esc(c)}</span>`).join("")}</div>`;
  return section("survey", title, own, `${tabs}<div class="ch-multi">${bars}</div>${key}`,
    "Weighted share of riders per answer; hover for the margin of error and respondents. The Green Line is one line in the survey, with no branch totals. It describes riders; it doesn't explain delays.");
}

// ---------------------------------------------------------------- 9. bunched / gapped trains (placeholder until the dbt build's columns land)
const BUNCH = [["bunched_share", "Bunched trains"], ["gapped_share", "Gapped trains"]];
async function bunchChart(ctx) {
  // the dbt build's headway_adherence.parquet (charts.headway_adherence_file): departures per scope x date x hour;
  // bunched / gapped by the SFMTA rules (methods: bunched_gapped). Day totals are exact sums of the hours.
  const title = "Bunched and gapped trains";
  const d = focusDay(ctx);
  const file = getPath(ctx.board, "charts.headway_adherence_file");
  const view = file && ctx.store.ensureFile ? await ctx.store.ensureFile(file) : null;
  if (!d || !view) return waiting("bunch", title, d ? day(d) : "", "headway_adherence.parquet");
  const scopes = ["system", ...routesOf(ctx.f.lineIds)];
  const hsel = ctx.xf && ctx.xf.kind === "hour" ? ctx.xf.hour : null;
  const rows = await ctx.store.query(`select scope_id, sum(departures_compared)::double as n, sum(bunched_departures)::double as b, sum(gapped_departures)::double as g
    from ${view} where service_date = ${sq(d)}::date and scope_id in (${scopes.map(sq).join(", ")})${Number.isInteger(hsel) ? ` and service_hour = ${hsel}` : ""} group by 1`);
  if (!rows || !rows.length) return section("bunch", title, day(d), `<p class="ch-wait">No recorded runs on this day.</p>`);
  const by = new Map(rows.map((r) => [r.scope_id, r]));
  const body = scopes.filter((s) => by.has(s)).map((s) => {
    const r = by.get(s), name = s === "system" ? "All subway lines" : routeName(s);
    const cell = (k, label) => {
      const v = r.n > 0 ? r[k] / r.n : null;
      const txt = r.n > 0 ? pct(v) : "No recorded runs";
      return `<span class="bg-v" ${tip(`${name}, ${day(d)}${Number.isInteger(hsel) ? ` ${hsel}:00` : ""}: ${txt} of departures ${label}`, `${int(r[k])} of ${int(r.n)} departures compared`)}>${esc(label)} <b>${esc(txt)}</b></span>`;
    };
    return `<li><span class="bg-k">${esc(name)}</span>${cell("b", "bunched")}${cell("g", "gapped")}</li>`;
  }).join("");
  const rule = ((getPath(ctx.board, "methods") || []).find((m) => m && m.id === "bunched_gapped") || {}).definition || "";
  return section("bunch", title, `${day(d)}${Number.isInteger(hsel) ? ` · ${String(hsel).padStart(2, "0")}:00 only` : ""}`, `<ul class="dw-l bg-l">${body}</ul>`, esc(rule));
}

export async function renderCharts(ctx) {
  const parts = await Promise.all([dailyChart, dayCompareChart, dayWorstChart, heatChart, bunchChart, histChart, donutChart, crChart, surveyChart].map((fn) => fn(ctx).catch((e) => {
    console.warn("[charts]", fn.name, e);
    return section("error", fn.name, "", `<p class="ch-wait">${esc(CHART_WAITING)}</p>`);
  })));
  return parts.join("");
}
