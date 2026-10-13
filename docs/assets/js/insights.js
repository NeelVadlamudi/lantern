// Insight cards: config-driven (config.js INSIGHT_CARDS). Every number comes from a configured dbt
// source (board_data.json path, Parquet table + column, or SQL). A token whose source is missing,
// null or ambiguous puts the whole card in its quiet waiting state: no fallbacks, no estimates,
// no stale values.
import { through, throughText } from "./sources.js";
import { TABLES } from "./queries.js";
import { STRETCH_METRICS, CARD_WAITING, TERMINAL, fallbackLineColor } from "./config.js";
import { sparkSvg } from "./ui.js";
import { formatDuration, exactSeconds } from "./duration.js";

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;
const sqlStr = (v) => `'${String(v).replace(/'/g, "''")}'`;

// ---------------------------------------------------------------- board_data.json paths
// "lines[route_id=Red].late_trip_share", "tiles[id=long_gap_share].value",
// "worst_stations[*].station_id" (array), "meta.service_date_window.last", "lines[0].color".
export function getPath(obj, path) {
  if (!obj || !path) return undefined;
  let cur = [obj];
  let many = false;
  for (const part of String(path).split(".")) {
    const m = part.match(/^([^[\]]+)(?:\[(.*)\])?$/);
    if (!m) return undefined;
    const [, key, sel] = m;
    let next = [];
    for (const c of cur) {
      const v = c == null ? undefined : c[key];
      if (sel == null) { next.push(v); continue; }
      if (!Array.isArray(v)) { next.push(undefined); continue; }
      if (sel === "*") { many = true; next.push(...v); continue; }
      if (/^\d+$/.test(sel)) { next.push(v[Number(sel)]); continue; }
      const eq = sel.match(/^([^=]+)=(.*)$/);
      if (!eq) { next.push(undefined); continue; }
      const hits = v.filter((x) => x && String(x[eq[1]]) === eq[2]);
      next.push(hits.length === 1 ? hits[0] : undefined); // 0 or >1 matches: ambiguous -> missing
    }
    cur = next;
  }
  return many ? cur.filter((x) => x !== undefined && x !== null) : cur[0];
}

// ---------------------------------------------------------------- sources
// src: { json } | { table, column, where } | { query }   (query: "{tableKey}" placeholders, column "v")
async function readSource(src, ctx) {
  if (!src) return undefined;
  if (src.json) return getPath(ctx.board, src.json);
  if (!ctx.store || !ctx.store.ready) return undefined;
  let sql = null;
  if (src.table && src.column) {
    if (!ctx.store.has(src.table) || !IDENT.test(src.column)) return undefined;
    const where = Object.entries(src.where || {});
    if (where.some(([k]) => !IDENT.test(k))) return undefined;
    sql = `select "${src.column}" as v from ${TABLES[src.table]}` +
      (where.length ? ` where ${where.map(([k, v]) => `"${k}" = ${sqlStr(v)}`).join(" and ")}` : "");
  } else if (src.query) {
    // {service_date} / {window_first} / {window_last}: board_data meta values (quoted ISO dates)
    const vals = { service_date: ctx.serviceDate, window_first: ctx.windowFirst, window_last: ctx.windowLast };
    // {worst_line} / {runner_up}: route ids from the dbt build's worst_line tile, allowlisted to route-id characters
    const wl = (ctx.board && Array.isArray(ctx.board.tiles) ? ctx.board.tiles : []).find((t) => t && t.id === "worst_line") || {};
    const ids = { worst_line: wl.value, runner_up: wl.runner_up_value };
    let ok = true;
    sql = src.query.replace(/\{(\w+)\}/g, (_, k) => {
      if (k in ids) { if (!/^[A-Za-z0-9-]{1,20}$/.test(String(ids[k] || ""))) ok = false; return sqlStr(ids[k]); }
      if (k in vals) { if (!/^\d{4}-\d{2}-\d{2}$/.test(String(vals[k] || ""))) ok = false; return sqlStr(vals[k]); }
      if (!ctx.store.has(k)) ok = false;
      return TABLES[k] || k;
    });
    if (!ok) return undefined;
  }
  if (!sql) return undefined;
  const rows = await ctx.store.query(sql);
  if (!rows) return undefined;
  if (src.rows) return rows.length ? rows : undefined;
  if (src.many) return rows.map((r) => r.v).filter((v) => v != null);
  return rows.length === 1 ? rows[0].v : undefined; // none or several rows: not a checked figure
}

// ---------------------------------------------------------------- formatting
// Returns { html, text, value } or null when the value does not qualify.
function formatToken(def, value, ctx) {
  const f = def.format || { type: "number" };
  switch (f.type) {
    case "percent": {
      if (!isNum(value)) return null;
      const pct = value * (f.scale ?? 100);
      const s = pct.toFixed(f.decimals ?? 1);
      return { value, text: s, html: `<span class="num">${esc(s)}</span>`, pctText: `${s}%` };
    }
    case "duration": {
      if (!isNum(value)) return null;
      const label = formatDuration(value, { signed: !!f.signed });
      const words = label.replace(/^[+\u2212]/, "").split(" ");
      const sign = label.startsWith("+") ? "+" : label.startsWith("\u2212") ? "\u2212" : "";
      let html = "";
      for (let i = 0; i < words.length; i += 2) html += `${i ? " " : ""}<span class="num">${i === 0 ? sign : ""}${esc(words[i])}</span>\u00a0${esc(words[i + 1] || "")}`;
      const ex = exactSeconds(value);
      return { value, text: label, html: `<span class="dur ins-dur" tabindex="0" title="${esc(ex)}" data-exact="${esc(ex)}">${html}</span>` };
    }
    case "one_in_n": {
      // Only when the config asks for it: N = 1 / share, rounded to a whole number.
      if (!isNum(value) || value <= 0 || value > 1) return null;
      const n = Math.round(1 / value);
      if (n < 1) return null;
      return { value, text: `1 in ${n}`, html: `<span class="num">1</span> in <span class="num">${n}</span>`, n };
    }
    case "count": {
      if (!isNum(value)) return null;
      const s = Math.round(value).toLocaleString("en-US");
      return { value, text: s, html: `<span class="num">${esc(s)}</span>` };
    }
    case "rows": {
      if (!Array.isArray(value) || !value.length) return null;
      return { value, text: "", html: "" };
    }
    case "daytype_plural": {
      const w = { weekday: "weekdays", saturday: "Saturdays", sunday: "Sundays", holiday: "holidays" }[String(value).toLowerCase()];
      return w ? { value, text: w, html: esc(w) } : null;
    }
    case "daytype_one": {
      const w = { weekday: "weekday", saturday: "Saturday", sunday: "Sunday", holiday: "holiday" }[String(value).toLowerCase()];
      return w ? { value, text: w, html: esc(w) } : null;
    }
    case "day_short": {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(String(value || ""))) return null;
      const t = shortDay(value);
      return { value, text: t, html: esc(t) };
    }
    case "date_range_to": {
      const [a, b] = String(value || "").split("|");
      if (!/^\d{4}-\d{2}-\d{2}$/.test(a || "") || !/^\d{4}-\d{2}-\d{2}$/.test(b || "")) return null;
      const t = `${shortDay(a)} to ${shortDay(b)}`;
      return { value, text: t, html: esc(t) };
    }
    case "date_range": {
      const [a, b] = String(value || "").split("|");
      if (!/^\d{4}-\d{2}-\d{2}$/.test(a || "") || !/^\d{4}-\d{2}-\d{2}$/.test(b || "")) return null;
      const t = `${shortDay(a)} – ${shortDay(b)}`;
      return { value, text: t, html: esc(t) };
    }
    // the dbt build's worst_line tile flags only (is_tie_overall, is_tie_weekday, display, weekday_display): the
    // page adds no ranking or test of its own. Any flag missing -> null (card waits).
    case "worst_line_verdict": {
      const t = value;
      if (!t || typeof t !== "object" || typeof t.is_tie_overall !== "boolean") return null;
      const nm = (s) => String(s || "").replace(/^Green Line ([A-E]) \(.*\)$/, "Green-$1").replace(/ Line$/, "");
      let txt;
      if (t.is_tie_overall) {
        if (t.is_tie_weekday === false && t.weekday_display) txt = `tie overall, ${nm(t.weekday_display)} worse on weekdays`;
        else if (t.is_tie_weekday === true) txt = "tie overall and on weekdays";
        else txt = "tie overall";
      } else {
        if (!t.display) return null;
        txt = `${nm(t.display)} worst overall`;
        if (t.is_tie_weekday === false && t.weekday_display && t.weekday_display !== t.display) txt += `, ${nm(t.weekday_display)} worse on weekdays`;
      }
      return { value: txt, text: txt, html: esc(txt) };
    }
    case "text": {
      if (typeof value !== "string" || !value.trim()) return null;
      return { value, text: value, html: esc(value) };
    }
    default: {
      if (!isNum(value)) return null;
      const s = value.toFixed(f.decimals ?? 0);
      return { value, text: s, html: `<span class="num">${esc(s)}</span>` };
    }
  }
}

const shortDay = (iso) => new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });

// Compare two displayed values (as rounded on screen, so the words always match the numbers shown).
function compareToken(d, a, b) {
  if (!a || !b || !isNum(a.value) || !isNum(b.value)) return null;
  const x = Number(a.text.replace(/[^0-9.\-]/g, "")), y = Number(b.text.replace(/[^0-9.\-]/g, ""));
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
  const w = x > y ? d.words.higher : x < y ? d.words.lower : d.words.same;
  return w ? { value: w, text: w, html: esc(w) } : null;
}

// The name whose displayed value is higher; null on a displayed tie (never picks a winner the numbers don't show).
function whichToken(a, b, na, nb) {
  if (!a || !b || !na || !nb) return null;
  const x = Number(a.text), y = Number(b.text);
  if (!Number.isFinite(x) || !Number.isFinite(y) || x === y) return null;
  return x > y ? na : nb;
}

// Resolve every token of one card variant. Returns { ok, tokens: {id: formatted}, missing: [ids] }.
export async function resolveTokens(variant, ctx) {
  const defs = variant.tokens || {};
  const out = {}, missing = [];
  const raw = {};
  const ids = Object.keys(defs);
  // plain sources first, then derived tokens
  for (const id of ids.filter((k) => !defs[k].derive)) {
    let v;
    try { v = await readSource(defs[id].source, ctx); } catch { v = undefined; }
    raw[id] = v;
    let fmtd = v == null ? null : formatToken(defs[id], v, ctx);
    // optional: a missing source renders as nothing (no "waiting" card); prefix only when present
    if (fmtd && defs[id].prefix) fmtd = { ...fmtd, text: defs[id].prefix + fmtd.text, html: esc(defs[id].prefix) + fmtd.html };
    if (!fmtd && defs[id].optional) fmtd = { value: null, text: "", html: "" };
    if (fmtd) out[id] = fmtd; else missing.push(id);
  }
  for (const id of ids.filter((k) => defs[k].derive)) {
    const d = defs[id].derive;
    const base = raw[d.from];
    const fmtd = d.as === "compare" ? compareToken(d, out[d.from], out[d.against])
      : d.as === "which" ? whichToken(out[d.from], out[d.against], out[d.names[0]], out[d.names[1]])
      : base == null || !out[d.from] ? null : formatToken({ format: { type: d.as } }, base, ctx);
    if (fmtd) out[id] = fmtd; else missing.push(id);
  }
  // tokens referenced in text but not defined (except the computed day label) are missing too
  const used = new Set();
  const tpls = [variant.answer, variant.means, variant.note, variant.visual && variant.visual.footer];
  for (const t of tpls) for (const m of String(t || "").matchAll(/\{(\w+)\}/g)) used.add(m[1]);
  for (const u of used) if (!["day_label", "day_label_sentence", "share"].includes(u) && !defs[u]) missing.push(u);
  if (variant.visual && variant.visual.token && !out[variant.visual.token]) missing.push(variant.visual.token);
  return { ok: missing.length === 0, tokens: out, missing };
}

// Map focus: { lines: [], segments: [], stations: [] }; each list may be literal or a source.
export async function resolveFocus(focus, ctx) {
  if (!focus) return null;
  const out = { lines: [], segments: [], stations: [], note: focus.note || "" };
  for (const k of ["lines", "segments", "stations"]) {
    const f = focus[k];
    if (!f) continue;
    if (Array.isArray(f)) out[k] = f.slice();
    else {
      let v;
      try { v = await readSource({ ...f, many: true }, ctx); } catch { v = undefined; }
      if (Array.isArray(v)) out[k] = v.map(String);
    }
  }
  return out.lines.length || out.segments.length || out.stations.length ? out : null;
}

// Template -> HTML. {token} renders the formatted value (lining tabular numerals); a "%" right after a
// percent token joins the number. {day_label}: "Yesterday" / "On Mon, Oct 5" at the start of a
// sentence, "yesterday" / "on Mon, Oct 5" elsewhere.
export function fillTemplate(tpl, tokens, day) {
  let html = "";
  let last = 0;
  const re = /\{(\w+)\}(%?)/g;
  let m;
  while ((m = re.exec(tpl))) {
    html += esc(tpl.slice(last, m.index));
    const before = tpl.slice(0, m.index).trimEnd();
    if (m[1] === "day_label" || m[1] === "day_label_sentence") {
      const start = m[1] === "day_label_sentence" || !before || /[.!?:]$/.test(before);
      html += day ? esc(start ? day.sentence : day.inline) : "";
    } else {
      const t = tokens[m[1]];
      html += t ? `<span class="ins-v${String(t.text ?? t.html ?? "").replace(/<[^>]*>/g, "").length > 24 ? " ins-v-long" : ""}">${t.html}${m[2] ? '<span class="num-unit">%</span>' : ""}</span>` : "";
    }
    last = m.index + m[0].length;
  }
  return html + esc(tpl.slice(last));
}

// ---------------------------------------------------------------- visuals
function colorOf(spec, lineColors) {
  if (!spec) return "#2B2118";
  const m = String(spec).match(/^line:(.+)$/);
  return m ? (lineColors[m[1]] || fallbackLineColor(m[1]) || "#2B2118") : spec;
}

// Pictogram: `dots` circles, filled by exactly share × dots (the last one partly), exact % beside.
function dotsHtml(v, tokens, lineColors) {
  const t = tokens[v.token];
  if (!t || !isNum(t.value)) return "";
  const n = v.dots || 10;
  const filled = Math.max(0, Math.min(n, t.value * n));
  const col = colorOf(v.color, lineColors);
  let dots = "";
  for (let i = 0; i < n; i++) {
    const f = Math.max(0, Math.min(1, filled - i));
    dots += `<i style="--f:${(f * 100).toFixed(1)}%;--c:${esc(col)}"></i>`;
  }
  const pct = t.pctText || `${(t.value * 100).toFixed(1)}%`;
  return `<div class="ins-dots" role="img" aria-label="${esc(pct)}, shown as ${esc((filled).toFixed(2))} of ${n} dots">
    <span class="ins-dots-row">${dots}</span><span class="ins-dots-k mono">${esc(pct)}${v.caption ? ` ${esc(v.caption)}` : ""}</span></div>`;
}

// Two-bar (or more) compare of durations, optional marker (e.g. the schedule).
function barsHtml(v, tokens, lineColors) {
  const bars = (v.bars || []).map((b) => ({ ...b,
    label: b.labelToken ? (tokens[b.labelToken] && tokens[b.labelToken].text) : b.label,
    color: b.colorToken ? (tokens[b.colorToken] && /^[A-Za-z0-9-]{1,20}$/.test(tokens[b.colorToken].text) ? `line:${tokens[b.colorToken].text.replace(/^Green-.*/, "Green")}` : null) : b.color,
    t: tokens[b.token] })).filter((b) => b.t && isNum(b.t.value) && b.label);
  if (bars.length < 2) return "";
  const mk = v.marker && tokens[v.marker.token] && isNum(tokens[v.marker.token].value) ? { ...v.marker, t: tokens[v.marker.token] } : null;
  const max = Math.max(...bars.map((b) => b.t.value), mk ? mk.t.value : 0);
  const col = colorOf(v.color, lineColors);
  const w = (x) => `${Math.max(1.5, (x / max) * 100).toFixed(1)}%`;
  return `<div class="ins-bars">${bars.map((b, i) => `
      <div class="ins-bar"><span class="ins-bar-k mono">${esc(b.label)}</span>
        <span class="ins-bar-track">${mk ? `<i class="ins-bar-mk" style="left:${w(mk.t.value)}" title="${esc(mk.label)}: ${esc(mk.t.text)}"></i>` : ""}<i class="ins-bar-fill" style="width:${w(b.t.value)};--c:${esc(b.color ? colorOf(b.color, lineColors) : col)};opacity:${b.color || i === bars.length - 1 ? 1 : 0.45}"></i></span>
        <span class="ins-bar-v mono">${esc(b.t.pctText || b.t.text)}</span></div>`).join("")}
      ${mk ? `<p class="ins-bar-note mono"><i class="ins-bar-mk-key"></i>${esc(mk.label)} ${esc(mk.t.text)}</p>` : ""}</div>`;
}

// Sparkline from a rows token; every point has a hover summary + exact detail (config tip templates).
const rowFmt = {
  date: (v) => (v ? new Date(`${String(v).slice(0, 10)}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" }) : "—"),
  duration: (v) => (isNum(v) ? formatDuration(v) : "—"),
  duration_signed: (v) => (isNum(v) ? formatDuration(v, { signed: true }) : "—"),
  text: (v) => (v == null ? "—" : String(v)),
};
const rowText = (tpl, row, fields) => String(tpl || "").replace(/\{(\w+)\}/g, (_, k) => (rowFmt[fields[k]] || rowFmt.text)(row[k]));
function sparkHtml(v, tokens) {
  const t = tokens[v.token];
  const rows = t && Array.isArray(t.value) ? t.value : [];
  if (rows.filter((r) => isNum(r[v.series[0].key])).length < 2) return "";
  const fields = v.fields || {};
  const exactKey = v.series[0].key;
  const svg = sparkSvg(rows, { x: v.x, series: v.series }, (r) => [
    rowText(v.tip && v.tip[0], r, fields),
    `${rowText(v.tip && v.tip[1], r, fields)} · exact ${isNum(r[exactKey]) ? exactSeconds(r[exactKey]) : "—"}`,
  ]);
  const first = rowFmt.date(rows[0][v.x]), last = rowFmt.date(rows[rows.length - 1][v.x]);
  return `<svg class="ins-spark" viewBox="0 0 240 34" preserveAspectRatio="none" role="img" aria-label="${esc(v.caption || "Trend")}">${svg}</svg>
    <p class="ins-bar-note mono">${esc(v.caption || "")} · ${esc(first)} – ${esc(last)}</p>`;
}

// Top 10 stretches by a STRETCH_METRICS entry; waiting while its value column is not configured.
export async function loadTopList(v, ctx) {
  const m = STRETCH_METRICS[v.metric];
  if (!m || !m.value || !IDENT.test(m.value) || (m.rank && !IDENT.test(m.rank))) return null;
  if (!ctx.store || !ctx.store.has("segments")) return null;
  const order = m.rank ? `"${m.rank}" asc` : `"${m.value}" desc`;
  const cols = ctx.store.columns ? await ctx.store.columns("segments") : null;
  const has = (c) => !!c && IDENT.test(c) && (!cols || cols.includes(c));
  const opt = (c, as) => (has(c) ? `, "${c}" as ${as}` : `, null as ${as}`);
  const rows = await ctx.store.query(`select segment_id, segment_name, line_id, from_station_name, to_station_name, "${m.value}" as v
      ${m.rank ? `, "${m.rank}" as rk` : ""}${opt(m.net, "net")}${opt(m.share, "share")}${opt(m.top, "top")}
      ${opt(TERMINAL.departure, "t_dep")}${opt(TERMINAL.arrival, "t_arr")}${opt(TERMINAL.split, "t_split")}${opt(TERMINAL.holdWeekday, "hold")}
    from ${TABLES.segments} where "${m.value}" is not null${m.rank ? ` and "${m.rank}" is not null` : ""} order by ${order} limit 10`);
  if (!rows || !rows.length || rows.some((r) => !isNum(r.v))) return null;
  return rows.map((r, i) => ({ ...r, rk: isNum(r.rk) ? r.rk : i + 1 }));
}

// Share of all stretch train delay held by the listed rows: sum of the share column (exact), or null.
export function topShare(rows) {
  if (!rows || !rows.length || rows.some((r) => !isNum(r.share))) return null;
  return rows.reduce((a, r) => a + r.share, 0);
}

// Terminal note for one row (same rules as the drawer).
function rowNote(r) {
  if (r.t_dep && isNum(r.hold) && TERMINAL.splitValues.includes(r.t_split)) return `+ ${formatDuration(r.hold)} waiting at ${r.from_station_name}, kept separate`;
  if (r.t_arr && !TERMINAL.splitValues.includes(r.t_split)) return TERMINAL.notSplitNote;
  return "";
}

const durSpan = (v, o) => `<span class="dur" tabindex="0" title="${esc(exactSeconds(v))}" data-exact="${esc(exactSeconds(v))}">${esc(formatDuration(v, o))}</span>`;
function topHtml(rows, lineColors, v) {
  const share = topShare(rows);
  const foot = v.footer && share != null ? `<p class="ins-top-foot mono">${esc(v.footer.replace("{share}", (share * 100).toFixed(1)).replace(/%%/, "%"))}</p>` : "";
  return `<p class="ins-top-k mono"><span>Stretch</span><span>Late per weekday · net</span></p>
    <ol class="rows ins-top">${rows.map((r) => { const note = rowNote(r); return `<li><button type="button" class="row" data-segment="${esc(r.segment_id)}">
      <span class="row-rk mono">${esc(r.rk)}</span><i class="row-dot" style="background:${esc(lineColors[r.line_id] || fallbackLineColor(r.line_id) || "#6B5B48")}"></i>
      <span class="row-nm">${esc(r.segment_name)}${note ? `<span class="row-note mono">${esc(note)}</span>` : ""}</span>
      <span class="row-v">${durSpan(r.v)}${isNum(r.net) ? `<span class="row-net mono">${durSpan(r.net, { signed: true })} net</span>` : ""}</span></button></li>`; }).join("")}</ol>${foot}`;
}

// ---------------------------------------------------------------- one card
// card: config entry; r: { variant, ok, tokens, top, focus }; opts: { day, windowText, lineColors, selected, mode }
export function cardHtml(card, r, opts) {
  const v = r.variant;
  const chips = (v && v.chips) || card.chips || [];
  const when = opts.mode === "day" ? (opts.day ? opts.day.label : "") : opts.windowText;
  // c.through: a meta.data_through key; the chip then carries that source's own date (e.g. gate entries).
  const chip = (c) => `<span class="est mono">${esc(c.text)}${c.basis && opts.mode !== "day" ? ` · ${esc(c.basis)}` : ""}${c.through && through(c.through) ? ` · ${esc(throughText(c.through, "").trim())}` : ""}</span>`;
  const chipsAt = (at) => { const h = chips.filter((c) => c.at === at).map(chip).join(""); return h ? `<div class="ins-chips">${h}</div>` : ""; };
  const chipHtml = (r.ok ? chips.filter((c) => !c.at) : chips).map(chip).join("")
    + (when ? `<span class="ins-when mono">${esc(when)}</span>` : "");
  const focusable = r.ok && !!r.focus;
  let body;
  if (!r.ok) {
    body = `<p class="ins-wait mono">${esc(CARD_WAITING)}</p>`;
  } else {
    const vis = v.visual || {};
    let visual = "";
    if (vis.type === "dots") visual = dotsHtml(vis, r.tokens, opts.lineColors);
    else if (vis.type === "bars") visual = barsHtml(vis, r.tokens, opts.lineColors);
    else if (vis.type === "spark") visual = sparkHtml(vis, r.tokens);
    else if (vis.type === "top10" && r.top) visual = topHtml(r.top, opts.lineColors, vis);
    body = `${v.answer ? `<p class="ins-a">${fillTemplate(v.answer, r.tokens, opts.day)}</p>${chipsAt("answer")}` : ""}
      ${visual}
      ${v.means ? `<p class="ins-m">${fillTemplate(v.means, r.tokens, opts.day)}</p>${chipsAt("means")}` : ""}
      ${v.note ? `<p class="ins-n mono">${/\{\w+\}/.test(v.note) ? fillTemplate(v.note, r.tokens, opts.day) : esc(v.note)}</p>` : ""}`;
  }
  const on = opts.selected === card.id;
  return `<article class="icard${on ? " is-on" : ""}${r.ok ? "" : " is-wait"}" data-card="${esc(card.id)}" role="listitem"
      ${focusable ? `tabindex="0" aria-pressed="${on}" aria-label="${esc(card.question)}: show on the map"` : ""}>
    <p class="ins-q mono">${esc(card.question)}</p>
    ${body}
    <div class="ins-foot">${chipHtml}${focusable ? `<span class="ins-map mono" aria-hidden="true">${on ? "Showing on map · tap to clear" : "Tap to show on map"}</span>` : ""}</div>
    ${on && r.focus && r.focus.note ? `<p class="ins-note mono">${esc(r.focus.note)}</p>` : ""}
    <p class="ins-def"><a href="#methods">How this is measured</a> · <a href="./dbt/index.html#!/overview">Methods in the dbt docs</a></p>
    ${card.caption ? `<p class="plate-cap">${esc(card.caption)}</p>` : ""}
  </article>`;
}
