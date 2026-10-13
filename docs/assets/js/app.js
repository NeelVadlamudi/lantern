// Wiring: state, data refresh, live polling, interactions.
import { CARD_WAITING, CONFIG, LINES, DAY_TYPES, stretchMetric, HERO, lineOfRoute, isCommuterRail, COMMUTER_RAIL, INSIGHT_CARDS, SERVICE_DATE, FREEDOM_TRAIL, STATEMENT } from "./config.js";
import { renderCharts, dowName } from "./charts.js";
import { resolveTokens, resolveFocus, loadTopList, cardHtml, getPath, fillTemplate } from "./insights.js";
import { serviceDayLabel } from "./daylabel.js";
import { formatDuration } from "./duration.js";
import { BOARD_KEYS, EXTRA_FILES, TABLES } from "./queries.js";
import { loadBoardData, loadJson, MartStore } from "./data.js";
import { loadNetwork, applyRouteColors, linesForStation } from "./network.js";
import { setSourceDates, throughText } from "./sources.js";
import { LiveTrains } from "./live.js";
import { BoardMap } from "./map.js";
import * as ui from "./ui.js";

const { $ } = ui;

const state = {
  lines: new Set(LINES.map((l) => l.line_id)),
  dayType: "all",       // all | weekday | saturday | sunday
  periodId: null,       // null = all day
  xf: null,             // chart cross-filter: { kind: "date" | "cell" | "bin", ... }
  chartsOpen: false,
  surveyTopic: null,
  ftOn: false,          // Freedom Trail marks (off by default)
  dateFrom: null,
  dateTo: null,
  dateBounds: null,
  selected: null,       // { type: "train"|"station"|"segment", id }
  tab: null,            // rail list: "top" | "worse" | "measures" | null (phones start closed)
  worseExpanded: false,
  segs: [],             // time-of-day layout
  vehicles: [],         // subway only: the only vehicles any subway view or figure may use
  crVehicles: [],       // Commuter Rail (live map layer only; never feeds subway figures)
  crView: false,        // map opens on the subway view
  last: null,           // last tile values (QA hook)
  cardSel: null,        // insight card shown on the map (id) or null
  serviceDate: null,    // latest service day in the dbt files ("YYYY-MM-DD")
  serviceDateSource: null,
  day: null,            // serviceDayLabel(serviceDate) at view time
};

const store = new MartStore();
let board = null;
let net = null;
let bmap = null;
let live = null;

// ---------------------------------------------------------------- layout
const SCROLL = document.body.classList.contains("layout-scroll");
// Scroll the map plate into view (scroll layout) unless most of it is already on screen.
function showMapPlate() {
  if (!SCROLL) return;
  const r = $("#map-plate").getBoundingClientRect();
  const vis = Math.min(innerHeight, r.bottom) - Math.max(0, r.top);
  if (vis < Math.min(r.height, innerHeight) * 0.7) $("#map-plate").scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "start" });
}
function trackSizes() {
  const root = document.documentElement.style;
  if (SCROLL) {
    const ro = new ResizeObserver(() => root.setProperty("--dock-h", `${$(".dock").offsetHeight}px`));
    ro.observe($(".dock"));
    return;
  }
  const ro = new ResizeObserver(() => {
    root.setProperty("--top-h", `${$(".topbar").offsetHeight}px`);
    root.setProperty("--dock-h", `${$(".dock").offsetHeight}px`);
    root.setProperty("--rail-h", `${$(".rail").offsetHeight}px`);
  });
  ro.observe($(".rail"));
  ro.observe($(".topbar"));
  ro.observe($(".dock"));
  const wide = () => document.body.classList.toggle("is-wide", innerWidth > 1180);
  wide();
  addEventListener("resize", wide);
}

// Right panel shows one thing at a time: "detail" (station/train), "lines" (comparison, rendered in the
// detail section) or "build". Closed by default.
const DRAWER_TITLES = { build: "How it's built", lines: "Lines", train: "Train", station: "Station", segment: "Track stretch", site: "Freedom Trail site" };
function openDrawer(mode) {
  const drawer = $("#drawer");
  const wasOpen = document.body.classList.contains("drawer-open");
  if (SCROLL && mode === "build") { $("#built").scrollIntoView({ behavior: "smooth", block: "start" }); return; }
  if (SCROLL && mode) showMapPlate();
  if (!mode) {
    document.body.classList.remove("drawer-open");
    drawer.dataset.view = "";
    $("#open-build").setAttribute("aria-pressed", "false");
  } else {
    drawer.dataset.mode = mode === "lines" ? "detail" : mode;
    drawer.dataset.view = mode;
    document.body.classList.add("drawer-open");
    $("#open-build").setAttribute("aria-pressed", String(mode === "build"));
    $("#drawer-title").textContent = mode === "detail" ? DRAWER_TITLES[(state.selected && state.selected.type) || "station"] : DRAWER_TITLES[mode];
    drawer.scrollTop = 0;
  }
  const lb = $("#open-lines");
  if (lb) lb.setAttribute("aria-pressed", String(mode === "lines"));
  if (bmap && wasOpen !== !!mode) setTimeout(() => bmap.refit(), 50);
}

// ---------------------------------------------------------------- filters
const routeIds = () => LINES.filter((l) => state.lines.has(l.line_id)).flatMap((l) => l.route_ids);
const isLatest = () => state.dayType === "latest" && !!state.serviceDate;
const plannedColCache = new Map();
async function hasPlannedCol(key) {
  if (!store.has(key)) return false;
  if (!plannedColCache.has(key)) { const c = await store.columns(key); plannedColCache.set(key, !!c && c.includes("is_planned_change")); }
  return plannedColCache.get(key);
}
const filters = () => ({
  routeIds: routeIds(),
  lineIds: [...state.lines],
  dayType: isLatest() ? "all" : state.dayType,
  riderDayType: ["saturday", "sunday", "weekday"].includes(state.dayType) ? state.dayType : "weekday", // gate entries: an average day of this type
  // Rider time lost follows the day toggle: weekday / saturday / sunday / all (every day with rider data).
  heroDay: ["weekday", "saturday", "sunday"].includes(state.dayType) ? state.dayType : "all",
  cellDay: ["saturday", "sunday"].includes(state.dayType) ? state.dayType : "weekday", // station drawer basis
  periodId: state.periodId,
  dow: state.xf && state.xf.kind === "cell" ? state.xf.dow : null, // heatmap cross-filter
  dateFrom: isLatest() ? state.serviceDate : state.dateFrom,
  dateTo: isLatest() ? state.serviceDate : state.dateTo,
});
const dayItems = () => (state.day ? [{ id: "latest", label: state.day.label, short: state.day.isYesterday ? "Yesterday" : state.day.label.replace(/^\w+, /, "") }] : []).concat(DAY_TYPES);
const dayLabel = () => (dayItems().find((d) => d.id === state.dayType) || {}).label || state.dayType;
const lineScope = () => (state.lines.size === LINES.length ? "All lines" : LINES.filter((l) => state.lines.has(l.line_id)).map((l) => l.label).join(", "));

const fullWindow = () => !isLatest() && (!state.dateBounds || (state.dateFrom === state.dateBounds.min && state.dateTo === state.dateBounds.max));
// Scope parts wrap as whole units (no-break spaces and word joiners inside each part).
const keep = (t) => String(t).replace(/ /g, "\u00a0").replace(/–/g, "\u2060–\u2060");
const dateText = () => (isLatest() ? keep(ui.fmt.day(state.serviceDate))
  : state.dateFrom && state.dateTo ? keep(`${ui.fmt.day(state.dateFrom)} – ${ui.fmt.day(state.dateTo)}`) : "");
const periodText = () => {
  if (!state.periodId) return keep("all day");
  const seg = state.segs.find((s) => s.service_period_id === state.periodId);
  return keep(seg ? `${seg.service_period_name} ${ui.periodRange(seg)}` : state.periodId);
};
const riderDayLabel = () => (["weekday", "saturday", "sunday"].includes(state.dayType) ? dayLabel() : "Weekday");

function scopeText() {
  if (!store.ready) return "No dbt build yet";
  return [dateText(), keep(dayLabel()), state.xf && state.xf.kind === "cell" ? keep(dowName(state.xf.dow)) : "", periodText()].filter(Boolean).join(" · ");
}

// Late trips and extra time per run for one time of day come from the period mart, which has no
// service date: say so when the date range is narrower than the loaded window.
const periodNote = () => [
  state.periodId && !fullWindow() ? "Time of day: all loaded days." : "",
  state.periodId && state.xf && state.xf.kind === "cell" ? "Trip figures for one time of day can't be split by day of week." : "",
].filter(Boolean).join(" ");

// dbt thresholds (meta.thresholds) for captions.
function thresholds() {
  const t = (board && board[BOARD_KEYS.meta] && board[BOARD_KEYS.meta].thresholds) || {};
  return {
    lateMin: Number.isFinite(t.late_trip_seconds) ? t.late_trip_seconds / 60 : null,
    gapRatio: Number.isFinite(t.long_gap_ratio) ? t.long_gap_ratio : null,
  };
}

// ---------------------------------------------------------------- dbt-driven panels
let refreshSeq = 0;
let refreshTimer = null;
function scheduleRefresh() {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refresh, 80);
}

// Percentile rank of gate entries in long gaps among stations with gate data (weekday basis unless
// Saturday or Sunday is selected). Stations dbt lists without gate data stay hollow.
function rankShade(rows) {
  const vals = rows.filter((r) => Number.isFinite(r.entries_in_long_gaps) && r.entries_in_long_gaps > 0 && !noGate.has(r.station_id))
    .sort((a, b) => a.entries_in_long_gaps - b.entries_in_long_gaps);
  const shade = new Map();
  const n = vals.length;
  vals.forEach((r, i) => shade.set(r.station_id, n > 1 ? i / (n - 1) : 1));
  for (const r of rows) if (!shade.has(r.station_id) && r.entries_in_long_gaps === 0) shade.set(r.station_id, 0);
  return shade;
}
let noGate = new Set();
let hotList = [];

async function refresh() {
  const seq = ++refreshSeq;
  $("#scope").textContent = scopeText();
  renderDateChip();
  renderCards();
  renderMainNumber();
  if (!store.ready) {
    ui.renderKpis(null, thresholds());
    bmap && bmap.setStationShading(null);
    return;
  }
  const f = filters();
  // the dbt build's headline tiles leave planned line-days out; match that wherever the flag column exists.
  f.noPlannedLine = await hasPlannedCol("lineDaily");
  f.noPlannedStation = await hasPlannedCol("stationDaily");
  const narrowed = state.lines.size !== LINES.length || !!state.periodId;
  // "All days" on the cell path needs the daily file for the day-type weights; else fall back to weekdays.
  const cellF = f.heroDay === "all" && !store.has("rtlDaily") ? { ...f, heroDay: "weekday" } : f;
  const heroP = narrowed
    ? store.has("stationTimeLost") ? store.run("heroByCell", cellF) : null
    : store.has("rtlDaily") ? store.run("heroByDate", f) : null;
  const [tripRows, gapRows, entryRows, shadeRows, stripRows, heroRows] = await Promise.all([
    f.periodId
      ? store.has("period") ? store.run("tripKpisByPeriod", f) : null
      : store.has("lineDaily") ? store.run("tripKpisByDate", f) : null,
    store.has("stationDaily") ? store.run("longGaps", f) : null,
    store.has("stationDaily", "station") ? store.run("entriesInLongGaps", f) : null,
    store.has("stationDaily", "station") ? store.run("stationShading", f) : null,
    store.has("periods", "stationDaily") ? store.run("periodStrip", f) : null,
    heroP,
  ]);
  if (seq !== refreshSeq) return; // a newer interaction superseded this one

  const hasRtl = store.has("rtlDaily") || store.has("stationTimeLost");
  const hv = (heroRows && heroRows[0]) || null;
  state.hero = hv;
  const basis = narrowed ? cellF.heroDay : f.heroDay;
  const heroWord = { weekday: "weekday", saturday: "Saturday", sunday: "Sunday", all: "day" }[basis];
  // Main number: measured train delay, whole window, from board_data.json (weekdays / all days only).
  renderMainNumber();
  ui.renderRider(hv, {
    keep: hasRtl,
    dayWord: heroWord,
    note: narrowed && !fullWindow() ? "Line and time-of-day estimates cover all loaded days." : "",
  });
  // Weekly trend is system-wide and exists for weekdays and all days only.
  const wkCol = basis === "weekday" ? "weekday_seconds" : basis === "all" ? "daily_seconds" : null;
  ui.renderSpark(!narrowed && wkCol && weekly ? weekly.map((w) => ({ ...w, seconds: w[wkCol] })) : null,
    { from: state.dateFrom, to: state.dateTo, unit: heroWord });

  const vals = { ...((tripRows && tripRows[0]) || {}), ...((gapRows && gapRows[0]) || {}), ...((entryRows && entryRows[0]) || {}) };
  state.last = vals;
  ui.renderKpis(vals, { ...thresholds(), riderDay: riderDayLabel(), periodNote: periodNote(), plannedOut: f.periodId ? !!(store.cleaned && store.cleaned.has(TABLES.period)) : !!f.noPlannedLine });

  if (shadeRows && shadeRows.length) {
    const shade = rankShade(shadeRows);
    hotList = shadeRows.filter((r) => shade.has(r.station_id)).sort((a, b) => b.entries_in_long_gaps - a.entries_in_long_gaps);
    bmap.setStationShading(shade);
  } else {
    hotList = [];
    bmap.setStationShading(null);
  }

  if (stripRows && stripRows.length) {
    state.segs = ui.layoutPeriods(stripRows);
    renderStrip();
  }
  $("#scope").textContent = scopeText();

  if (state.selected && state.selected.type === "station") showStation(state.selected.id, false);
  if ($("#drawer").dataset.view === "lines") showLines(false);
  drawCharts();
  writeUrl();
}

// ---------------------------------------------------------------- shareable URL state (untrusted input: allowlisted)
const ISO = /^\d{4}-\d{2}-\d{2}$/;
let urlApplying = false;
function readUrl() {
  const q = new URLSearchParams(location.search);
  const out = {};
  const day = q.get("day");
  if (day && ["latest", ...DAY_TYPES.map((d) => d.id)].includes(day)) out.dayType = day;
  const from = q.get("from"), to = q.get("to");
  const inB = (d) => ISO.test(d || "") && (!state.dateBounds || (d >= state.dateBounds.min && d <= state.dateBounds.max));
  if (inB(from) && inB(to)) { out.dateFrom = from <= to ? from : to; out.dateTo = from <= to ? to : from; } // a reversed range is swapped, never dropped
  const ln = q.get("lines");
  if (ln) { const ids = ln.split(",").filter((x) => LINES.some((l) => l.line_id === x)); if (ids.length) out.lines = new Set(ids); }
  const per = q.get("period");
  if (per && (state.segs || []).some((p) => p.service_period_id === per)) out.periodId = per;
  const st = q.get("station");
  if (st && /^[A-Za-z0-9_-]{1,40}$/.test(st) && net && net.stations.has(st)) out.station = st;
  const hm = q.get("heat");
  if (hm && ["delay", "late", "gaps"].includes(hm)) out.heatMeasure = hm;
  return out;
}
function applyUrl() {
  const u = readUrl();
  urlApplying = true;
  state.dayType = u.dayType || "all";
  if (u.dateFrom) { state.dateFrom = u.dateFrom; state.dateTo = u.dateTo; }
  else if (state.dateBounds) { state.dateFrom = state.dateBounds.min; state.dateTo = state.dateBounds.max; }
  state.lines = u.lines || new Set(LINES.map((l) => l.line_id));
  state.periodId = u.periodId || null;
  state.heatMeasure = u.heatMeasure || null;
  state.xf = null;
  if (bmap) { ui.renderLineChips(bmap.lineColors, state.lines, onLineChip); bmap.setSelectedLines(state.lines); }
  renderDayControl(); syncDateInputs(); if (state.segs && state.segs.length) renderStrip();
  if (u.station) showStation(u.station); else if (state.selected && state.selected.type === "station") clearSelection();
  scheduleRefresh();
  setTimeout(() => { urlApplying = false; }, 200);
}
function writeUrl() {
  if (urlApplying) return;
  const q = new URLSearchParams();
  if (state.dayType && state.dayType !== "all") q.set("day", state.dayType);
  if (state.dateBounds && state.dateFrom && (state.dateFrom !== state.dateBounds.min || state.dateTo !== state.dateBounds.max)) { q.set("from", state.dateFrom); q.set("to", state.dateTo); }
  if (state.lines.size !== LINES.length) q.set("lines", [...state.lines].join(","));
  if (state.periodId) q.set("period", state.periodId);
  if (state.selected && state.selected.type === "station") q.set("station", state.selected.id);
  if (state.heatMeasure) q.set("heat", state.heatMeasure);
  const next = q.toString() ? `?${q}` : location.pathname;
  if (`${location.search}` !== (q.toString() ? `?${q}` : "")) history.pushState(null, "", next + location.hash);
}
let onLineChip = () => {};
function setOnlyLine(id) {
  if (!LINES.some((l) => l.line_id === id)) return;
  state.lines = state.lines.size === 1 && state.lines.has(id) ? new Set(LINES.map((l) => l.line_id)) : new Set([id]);
  if (bmap) { ui.renderLineChips(bmap.lineColors, state.lines, onLineChip); bmap.setSelectedLines(state.lines); }
  scheduleRefresh();
}
window.addEventListener("popstate", () => applyUrl());

// ---------------------------------------------------------------- charts panel + cross-filter
let chartSeq = 0;
function chartScope(dims) {
  const parts = [];
  if (dims.includes("dates")) parts.push(dateText());
  if (dims.includes("dayType")) parts.push(keep(dayLabel()));
  if (dims.includes("dow") && state.xf && state.xf.kind === "cell") parts.push(keep(dowName(state.xf.dow)));
  if (dims.includes("lines")) parts.push(keep(lineScope()));
  return parts.filter(Boolean).join(" · ");
}
async function drawCharts() {
  if (!state.chartsOpen) return;
  const seq = ++chartSeq;
  const f = filters();
  const stationId = state.selected && state.selected.type === "station" ? state.selected.id : null;
  const html = await renderCharts({
    store, board, f: { ...f, stationId }, xf: state.xf, periods: state.segs || [], lineColors: (bmap && bmap.lineColors) || {},
    scope: chartScope, periodRange: (p) => ui.periodRange(p), surveyTopic: state.surveyTopic, serviceDate: state.serviceDate, heatMeasure: state.heatMeasure,
    stationName: (id) => (net && net.stations.get(id) ? net.stations.get(id).name : id),
    stationLines: (id) => (net && net.stations.get(id) ? linesForStation(net.stations.get(id)).map((l) => l.line_id) : []),
  });
  if (seq !== chartSeq) return;
  $("#charts-body").innerHTML = html;
  const xf = $("#charts-xf");
  xf.hidden = !state.xf;
  if (state.xf) xf.innerHTML = `${ui.esc(xfText())} <button type="button" class="xf-clear" id="xf-clear">Clear</button>`;
  $("#charts-scope").textContent = SCROLL ? "The charts below follow the dates, day, lines and station picked in the strip at the bottom; tap a cell or bar to filter the map and the other charts (tap again or Esc to clear). The survey keeps its own dates."
    : "Charts follow the dates, day, lines and station picked; the survey keeps its own dates.";
}
function xfText() {
  const x = state.xf;
  if (!x) return "";
  if (x.kind === "date") return `Filtered to ${ui.fmt.day(x.date)} from the chart (map, measures, charts)`;
  if (x.kind === "cell") {
    const seg = (state.segs || []).find((p) => p.service_period_id === x.periodId);
    return `Filtered to ${dowName(x.dow)}, ${seg ? seg.service_period_name : x.periodId} from the heatmap (map, measures, charts)`;
  }
  if (x.kind === "hour") return `Highlighting ${String(x.hour % 24).padStart(2, "0")}:00 in the hourly chart (other charts have no hour column yet)`;
  if (x.kind === "bin") return `Highlighting ${x.bin}–${x.bin + 1} min late (other charts have no lateness column)`;
  return "";
}
function setCross(next) {
  const cur = state.xf;
  const same = cur && next && cur.kind === next.kind && ((next.kind === "date" && cur.date === next.date) || (next.kind === "cell" && cur.dow === next.dow && cur.periodId === next.periodId) || (next.kind === "bin" && cur.bin === next.bin));
  // restore whatever the previous pick replaced
  if (cur) {
    if (cur.kind === "date") { state.dateFrom = cur.prev.dateFrom; state.dateTo = cur.prev.dateTo; state.dayType = cur.prev.dayType; }
    if (cur.kind === "cell") state.periodId = cur.prev.periodId;
  }
  state.xf = null;
  if (next && !same) {
    if (next.kind === "date") { next.prev = { dateFrom: state.dateFrom, dateTo: state.dateTo, dayType: state.dayType }; state.dateFrom = state.dateTo = next.date; if (state.dayType === "latest") state.dayType = "all"; }
    if (next.kind === "cell") { next.prev = { periodId: state.periodId }; state.periodId = next.periodId; }
    state.xf = next;
  }
  renderDayControl();
  syncDateInputs();
  if (state.segs && state.segs.length) renderStrip();
  scheduleRefresh();
}
function syncDateInputs() {
  const a = $("#date-from"), b = $("#date-to");
  if (a && state.dateFrom) a.value = state.dateFrom;
  if (b && state.dateTo) b.value = state.dateTo;
}
function setChartsOpen(open) {
  state.chartsOpen = open;
  $("#charts").hidden = !open;
  document.body.classList.toggle("charts-open", open);
  $("#open-charts").setAttribute("aria-pressed", String(open));
  if (open) drawCharts();
  if (bmap) setTimeout(() => bmap.refit(), 60);
}
function setupCharts() {
  if (SCROLL) state.chartsOpen = true; // charts are plates on the page, always drawn
  else {
    $("#open-charts").addEventListener("click", () => setChartsOpen(!state.chartsOpen));
    $("#charts-close").addEventListener("click", () => setChartsOpen(false));
  }
  $("#charts").addEventListener("click", (e) => {
    if (e.target.closest("#xf-clear")) { setCross(null); return; }
    const sv = e.target.closest("[data-survey]");
    if (sv) { state.surveyTopic = sv.dataset.survey; drawCharts(); return; }
    const ln = e.target.closest(".xf-line[data-line]");
    if (ln && ln.dataset.line) { setOnlyLine(ln.dataset.line); return; }
    const st = e.target.closest(".xf-st[data-station]");
    if (st) { showStation(st.dataset.station); if (bmap) setTimeout(() => bmap.focus({ stationId: st.dataset.station }), 60); return; }
    const hr = e.target.closest("[data-xf=hour]");
    if (hr) { const h = Number(hr.dataset.hour); state.xf = state.xf && state.xf.kind === "hour" && state.xf.hour === h ? null : { kind: "hour", hour: h }; drawCharts(); return; }
    const hm = e.target.closest("[data-heat]");
    if (hm) { state.heatMeasure = hm.dataset.heat; drawCharts(); return; }
    const m = e.target.closest("[data-xf]");
    if (!m) return;
    const k = m.dataset.xf;
    if (k === "date") setCross({ kind: "date", date: m.dataset.date });
    else if (k === "cell") setCross({ kind: "cell", dow: Number(m.dataset.dow), periodId: m.dataset.period });
    else if (k === "bin") { state.xf = state.xf && state.xf.kind === "bin" && state.xf.bin === Number(m.dataset.bin) ? null : { kind: "bin", bin: Number(m.dataset.bin) }; drawCharts(); }
  });
  $("#charts").addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && e.target.matches("[role=button]")) { e.preventDefault(); e.target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true })); }
  });
  // Charts load their (lazy) files only when the plates come near the viewport.
  if (SCROLL && "IntersectionObserver" in window) {
    state.chartsOpen = false;
    const io = new IntersectionObserver(([en]) => { if (en.isIntersecting) { state.chartsOpen = true; io.disconnect(); drawCharts(); } }, { rootMargin: "800px 0px" });
    io.observe($("#charts"));
  }
  // Hover tooltips for every chart / sparkline mark: summary + exact detail (data-tip-s / data-tip-d).
  const tipFor = (el) => {
    const f = document.createDocumentFragment();
    const a = document.createElement("p"); a.className = "tip-s"; a.textContent = el.dataset.tipS; f.append(a);
    if (el.dataset.tipD) { const b = document.createElement("p"); b.className = "tip-m"; b.textContent = el.dataset.tipD; f.append(b); }
    return f;
  };
  document.addEventListener("pointerover", (e) => { const el = e.target.closest && e.target.closest("[data-tip-s]"); if (el) ui.showTip(tipFor(el), { x: e.clientX, y: e.clientY }); });
  document.addEventListener("pointermove", (e) => { const el = e.target.closest && e.target.closest("[data-tip-s]"); if (el && e.pointerType === "mouse") ui.showTip(tipFor(el), { x: e.clientX, y: e.clientY }); });
  document.addEventListener("pointerout", (e) => { const el = e.target.closest && e.target.closest("[data-tip-s]"); if (el && e.pointerType === "mouse" && !(e.relatedTarget && el.contains(e.relatedTarget))) ui.hideTip(); });
  // Keyboard: one tab stop per chart graphic (roving tabindex); arrow keys / Home / End step through its
  // marks, each focused mark shows the same tooltip (textContent) and is named for screen readers.
  const groupOf = (el) => el.closest("svg, .ins-bars, .ch-dots") || el.parentElement;
  const marksIn = (g) => [...g.querySelectorAll("[data-tip-s]")];
  const prepRoving = () => {
    const seen = new Set();
    for (const m of document.querySelectorAll("[data-tip-s]")) {
      const g = groupOf(m); if (!g || seen.has(g)) continue; seen.add(g);
      const ms = marksIn(g);
      if (g.tagName.toLowerCase() === "svg" && g.getAttribute("role") === "img") { g.setAttribute("role", "group"); }
      const cur = ms.find((x) => x.getAttribute("tabindex") === "0") || ms[0];
      for (const x of ms) {
        if (x !== cur) x.setAttribute("tabindex", "-1"); else x.setAttribute("tabindex", "0");
        if (!x.hasAttribute("aria-label")) x.setAttribute("aria-label", [x.dataset.tipS, x.dataset.tipD].filter(Boolean).join(". "));
        if (!x.hasAttribute("role")) x.setAttribute("role", x.dataset.xf || x.classList.contains("xf-line") ? "button" : "img");
      }
    }
  };
  let rovT = null, kbTip = false;
  new MutationObserver(() => { clearTimeout(rovT); rovT = setTimeout(prepRoving, 60); }).observe(document.body, { childList: true, subtree: true });
  prepRoving();
  document.addEventListener("focusin", (e) => {
    const el = e.target.closest && e.target.closest("[data-tip-s]");
    if (!el || !el.matches(":focus-visible")) return;
    kbTip = true;
    const r = el.getBoundingClientRect();
    ui.showTip(tipFor(el), { x: r.left + r.width / 2, y: r.bottom });
  });
  // Only hide what the keyboard opened: a tap shows the tip by pointer and must keep it.
  document.addEventListener("focusout", (e) => { if (kbTip && e.target.closest && e.target.closest("[data-tip-s]")) { kbTip = false; ui.hideTip(); } });
  document.addEventListener("keydown", (e) => {
    const el = e.target.closest && e.target.closest("[data-tip-s]");
    if (!el) return;
    if (e.key === "Escape") { ui.hideTip(); return; }
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
    if (!step && e.key !== "Home" && e.key !== "End") return;
    const ms = marksIn(groupOf(el)); const i = ms.indexOf(el);
    const j = e.key === "Home" ? 0 : e.key === "End" ? ms.length - 1 : Math.max(0, Math.min(ms.length - 1, i + step));
    e.preventDefault();
    if (j === i) return;
    el.setAttribute("tabindex", "-1"); ms[j].setAttribute("tabindex", "0"); ms[j].focus();
  });
}

// ---------------------------------------------------------------- Freedom Trail (the dbt build's table)
let ftSites = null;
const ftLines = (v) => (Array.isArray(v) ? v : String(v || "").split(/[|,;\s]+/)).map(String).filter(Boolean);
function ftRow(r) {
  const C = FREEDOM_TRAIL.columns;
  return { order: r[C.order], name: r[C.name], lat: r[C.lat], lon: r[C.lon], stopId: r[C.stopId], stopName: r[C.stopName],
    lines: ftLines(r[C.stopLines]), distanceLabel: r[C.distanceLabel], walk: r[C.walkSeconds], basis: r[C.walkBasis], source: r[C.source], note: r[C.note] };
}
async function setFreedomTrail(on) {
  state.ftOn = on;
  $("#ft-toggle").setAttribute("aria-pressed", String(on));
  const note = $("#ft-note");
  if (!store.has("freedomTrail")) {
    note.hidden = !on;
    note.textContent = FREEDOM_TRAIL.waiting;
    if (bmap) bmap.setFreedomTrail([], false);
    return;
  }
  note.hidden = !on;
  note.textContent = on ? `Dotted line: ${FREEDOM_TRAIL.pathLabel}.` : "";
  if (!ftSites && window.__lanternStartMarts) await window.__lanternStartMarts();
  if (!ftSites) { const rows = await store.run("freedomTrail"); ftSites = (rows || []).map(ftRow); }
  await bmap.setFreedomTrail(ftSites, on, { pathLabel: FREEDOM_TRAIL.pathLabel });
  if (!on) bmap.markStation(null);
}
// ---------------------------------------------------------------- Commuter Rail track shapes (map files, mode column)
async function loadCommuterRailNetwork() {
  if (!(await store.init(board)) || !store.has("crShapes")) return;
  const pts = await store.query(`select route_id, branch_route_id, direction_id, longitude as lon, latitude as lat
    from ${TABLES.crShapes} where mode = 'commuter_rail' order by route_id, branch_route_id, direction_id, point_order`);
  if (!pts || !pts.length) return;
  const byKey = new Map();
  for (const p of pts) {
    const k = `${p.route_id}|${p.branch_route_id}|${p.direction_id}`;
    if (!byKey.has(k)) byKey.set(k, { route_id: p.route_id, coords: [] });
    byKey.get(k).coords.push([p.lon, p.lat]);
  }
  const features = [...byKey.values()].filter((f) => f.coords.length > 1).map((f) => ({ type: "Feature", properties: { route_id: f.route_id }, geometry: { type: "LineString", coordinates: f.coords } }));
  let stations = [];
  if (store.has("crStations")) {
    const st = await store.query(`select station_id as id, station_name as name, longitude as lon, latitude as lat from ${TABLES.crStations} where list_contains(modes, 'commuter_rail')`);
    stations = st || [];
  }
  bmap.setCommuterRailNetwork(features, stations);
}

// ---------------------------------------------------------------- "Was my line worse than usual, and where?"
const MY_ROUTES = ["Red", "Mattapan", "Orange", "Green", "Green-B", "Green-C", "Green-D", "Green-E", "Blue"];
const MY_NAMES = { Green: "Green (all branches)", Red: "Red", Mattapan: "Mattapan", Orange: "Orange", "Green-B": "Green B", "Green-C": "Green C", "Green-D": "Green D", "Green-E": "Green E", Blue: "Blue" };
const nOfD = (r, m) => m !== "train_delay_positive_per_run_seconds" && r && Number.isFinite(r.numerator) && Number.isFinite(r.denominator) && r.denominator > 0
  ? `, ${Math.round(r.numerator).toLocaleString("en-US")} of ${Math.round(r.denominator).toLocaleString("en-US")}` : "";
const MY_MEASURES = [["late_trip_share", "trips late", (v) => `${(v * 100).toFixed(1)}%`], ["long_gap_share", "departures after a long gap", (v) => `${(v * 100).toFixed(1)}%`],
  ["train_delay_positive_per_run_seconds", "late time per run", (v) => `${v.toFixed(1)} s`]];
function setupMyLine() {
  const box = $("#myline-pick");
  if (!box) return;
  box.replaceChildren(...MY_ROUTES.map((id) => {
    const b = document.createElement("button"); b.type = "button"; b.className = "chip"; b.dataset.route = id; b.setAttribute("aria-pressed", "false");
    const dot = document.createElement("span"); dot.className = "chip-dot"; dot.style.background = (LINES.find((l) => l.line_id === id || l.route_ids.includes(id)) || {}).fallbackColor || "#2B2118";
    b.append(dot, document.createTextNode(MY_NAMES[id])); return b;
  }));
  box.addEventListener("click", (e) => { const b = e.target.closest("[data-route]"); if (b) answerMyLine(b.dataset.route, true); });
}
let mySeq = 0;
let myRoute = "Red";
async function answerMyLine(route, user = false) {
  if (!MY_ROUTES.includes(route)) return;
  myRoute = route;
  const seq = ++mySeq;
  for (const b of document.querySelectorAll("#myline-pick [data-route]")) b.setAttribute("aria-pressed", String(b.dataset.route === route));
  const a = $("#myline-a"), w = $("#myline-w");
  const d = state.serviceDate;
  if (d && !store.ready) {
    // Before DuckDB: the same latest-day rows from board_data.json latest_day (value + typical median).
    // The verdict needs the dbt build's p25/p75, which only line_day_metrics carries, so it waits for a pick.
    const sc = (getPath(board, "latest_day.scopes") || []).find((s) => s && s.scope_id === route);
    const parts = [];
    for (const [m, label, fmt] of MY_MEASURES) {
      const r = sc && sc.measures && sc.measures[m];
      if (!r || !Number.isFinite(r.value)) continue;
      parts.push(`${fmt(r.value)}${nOfD(r, m)} ${label}${Number.isFinite(r.typical_median) ? `, typical ${fmt(r.typical_median)}` : ""}`);
    }
    a.textContent = parts.length ? `${ui.fmt.day(d)}, ${MY_NAMES[route]}: ${parts.join("; ")}.` : CARD_WAITING;
    w.textContent = user ? "Loading whether it was worse than usual, and where…" : "Pick a line for whether it was worse than usual, and where.";
    if (user && window.__lanternStartMarts) window.__lanternStartMarts();
    return;
  }
  if (!d || !store.has("lineDayMetrics")) { a.textContent = CARD_WAITING; w.textContent = ""; return; }
  const rows = await store.query(`select measure, value, numerator, denominator, typical_median, typical_p25, typical_p75, typical_days, day_type
    from ${TABLES.lineDayMetrics} where scope_id = '${route}' and service_date = '${d}'::date and measure in ('late_trip_share', 'long_gap_share', 'train_delay_positive_per_run_seconds')`);
  if (seq !== mySeq) return;
  if (!rows || !rows.length) { a.textContent = `No recorded runs for ${MY_NAMES[route]} on ${ui.fmt.day(d)}.`; w.textContent = ""; return; }
  const parts = [], worse = [];
  for (const [m, label, fmt] of MY_MEASURES) {
    const r = rows.find((x) => x.measure === m);
    if (!r || !Number.isFinite(r.value)) continue;
    const typ = Number.isFinite(r.typical_median) ? `, typical ${fmt(r.typical_median)}` : "";
    const tag = Number.isFinite(r.typical_p75) && r.value > r.typical_p75 ? " (worse than usual)" : Number.isFinite(r.typical_p25) && r.value < r.typical_p25 ? " (better than usual)" : Number.isFinite(r.typical_p25) ? " (about usual)" : "";
    if (tag === " (worse than usual)") worse.push(label);
    parts.push(`${fmt(r.value)}${nOfD(r, m)} ${label}${typ}${tag}`);
  }
  const dt = ({ weekday: "weekday", saturday: "Saturday", sunday: "Sunday", holiday: "holiday" })[String(rows[0].day_type).toLowerCase()] || rows[0].day_type;
  const verdict = worse.length ? `Yes, worse than a typical ${dt} on ${worse.join(" and ")}.` : `No, not worse than a typical ${dt}.`;
  a.textContent = `${ui.fmt.day(d)}, ${MY_NAMES[route]}: ${verdict} ${parts.join("; ")}.`;
  const cp = await store.ensureFile(getPath(board, "charts.completeness_file"));
  const cr = cp ? await store.query(`select completeness_share as c, is_low_completeness as low from ${cp} where scope_id = '${route}' and service_date = '${d}'::date`) : null;
  if (seq !== mySeq) return;
  if (cr && cr.length === 1 && cr[0].low === true) a.textContent += ` Incomplete data: ${Math.round(cr[0].c * 100)}% of scheduled trips were compared on this day, so runs may be missing.`;
  w.textContent = "";
  const [okS, okT] = await Promise.all([store.ensure("dayWorstSegments"), store.ensure("dayWorstStations")]);
  if (seq !== mySeq) return;
  const seg = okS ? await store.query(`select segment_name, positive_excess_seconds from ${TABLES.dayWorstSegments} where scope_id = '${route}' and service_date = '${d}'::date and day_rank = 1`) : null;
  const st = okT ? await store.query(`select station_name, long_gaps, headway_observations from ${TABLES.dayWorstStations} where scope_id = '${route}' and service_date = '${d}'::date and day_rank = 1`) : null;
  if (seq !== mySeq) return;
  const bits = [];
  if (seg && seg.length === 1) bits.push(`the stretch with the most train delay was ${seg[0].segment_name} (${formatDuration(seg[0].positive_excess_seconds)})`);
  if (st && st.length === 1) bits.push(`the station with the most long gaps was ${st[0].station_name} (${Math.round(st[0].long_gaps).toLocaleString("en-US")} of ${Math.round(st[0].headway_observations).toLocaleString("en-US")} departures)`);
  w.textContent = bits.length ? `Where: ${bits.join("; ")}.`
    : route === "Green" ? "Where: the day's worst stretches and stations are listed per branch; pick Green B, C, D or E." : `Where: ${CARD_WAITING}`;
}

// ---------------------------------------------------------------- methods block (board_data glossary + rules, linked to the dbt docs)
function renderMethods() {
  const dl = $("#methods-list");
  if (!dl) return;
  const g = Array.isArray(board && board.glossary) ? board.glossary : [];
  const rules = [["Typical day", "latest_day.typical_rule"], ["Hour ratings", "meta.thresholds.usual_rule"], ["Worst stretches of a day", "latest_day.worst_segments_rule"],
    ["Worst stations of a day", "latest_day.worst_stations_rule"], ["Commuter Rail on time", "commuter_rail.on_time_rule"]];
  const items = g.filter((x) => x && x.term && x.meaning).map((x) => [x.term, x.meaning, "board_data.json glossary"])
    .concat(rules.map(([t, p]) => [t, getPath(board, p), `board_data.json ${p}`]).filter((x) => typeof x[1] === "string"));
  const nodes = [];
  // the dbt build's methods (board_data.methods): definition, where it is used, and its outside source.
  for (const m of Array.isArray(board && board.methods) ? board.methods : []) {
    if (!m || typeof m.name !== "string" || typeof m.definition !== "string") continue;
    const dt = document.createElement("dt"); dt.textContent = m.name; dt.id = `method-${String(m.id || "").replace(/[^a-z0-9_-]/gi, "")}`;
    const dd = document.createElement("dd"); dd.textContent = m.definition + " ";
    if (typeof m.used_here === "string") { const u = document.createElement("span"); u.className = "methods-src"; u.textContent = `Used for: ${m.used_here}. `; dd.append(u); }
    const s = document.createElement("span"); s.className = "methods-src";
    if (typeof m.source_url === "string" && /^https:\/\//.test(m.source_url)) {
      s.append("Source: "); const a = document.createElement("a"); a.href = m.source_url; a.rel = "noopener noreferrer"; a.textContent = m.source_name || m.source_url; s.append(a, " · ");
    } else s.append("Source: this build · ");
    const ln = document.createElement("a"); ln.href = "./dbt/index.html#!/overview"; ln.textContent = "Methods in the dbt docs"; s.append(ln); dd.append(s);
    nodes.push(dt, dd);
  }
  if (!items.length && !nodes.length) return;
  for (const [t, m, src] of items) {
    const dt = document.createElement("dt"); dt.textContent = t;
    const dd = document.createElement("dd"); dd.textContent = m + " ";
    const s = document.createElement("span"); s.className = "methods-src"; s.textContent = `Source: ${src} · `;
    const ln = document.createElement("a"); ln.href = "./dbt/index.html#!/overview"; ln.textContent = "Methods in the dbt docs"; s.append(ln); dd.append(s);
    nodes.push(dt, dd);
  }
  dl.replaceChildren(...nodes);
}

// ---------------------------------------------------------------- opening statement (scroll page)
let stSeq = 0;
async function renderStatement() {
  if (!SCROLL) return;
  const seq = ++stSeq;
  const w = (board && board.meta && board.meta.service_date_window) || {};
  const ctx = { board, store, serviceDate: state.serviceDate, windowFirst: w.first, windowLast: w.last };
  // Thin typical on the latest day: drop every typical token (they are empty by design) and use meansThin.
  const thin = getPath(board, STATEMENT.thinJson) === true;
  const V = thin ? { ...STATEMENT, means: STATEMENT.meansThin,
    tokens: { ...Object.fromEntries(Object.entries(STATEMENT.tokens).filter(([k]) => !/_typ|^typ_|^sys_p(25|75)$/.test(k))), ...STATEMENT.thinTokens } } : STATEMENT;
  const r = state.serviceDate && state.day ? await resolveTokens(V, ctx) : { ok: false };
  if (seq !== stSeq) return;
  $("#st-text").innerHTML = r.ok ? fillTemplate(V.answer, r.tokens, state.day) : ui.esc(STATEMENT.waiting);
  const thrMin = getPath(board, "meta.thresholds.late_trip_seconds") / 60;
  const dlead = (() => { const [y, m, dd] = String(state.serviceDate || "").split("-").map(Number); const dt = new Date(Date.UTC(y, m - 1, dd)); return isNaN(dt) ? "" : dt.toLocaleDateString("en-US", { timeZone: "UTC", weekday: "short", month: "short", day: "numeric" }).replace(/,/g, ""); })();
  $("#st-sub").innerHTML = r.ok && dlead && Number.isFinite(thrMin) ? fillTemplate(V.means, r.tokens, state.day).replace("%DATE%", ui.esc(dlead)).replace("%THR%", ui.esc(String(thrMin))) : "";
  const tw = r.ok && !thin && r.tokens.typ_first && r.tokens.typ_days ? ` · typical = median of the ${r.tokens.typ_days.text} earlier ${ui.esc(r.tokens.sys_daytype.text)}s, ${ui.esc(ui.fmt.day(r.tokens.typ_first.text))} – ${ui.esc(ui.fmt.day(r.tokens.typ_last.text))}` : "";
  $("#st-cap").innerHTML = r.ok
    ? `${STATEMENT.chips.map((c) => `<span class="est">${ui.esc(c.text)}</span>`).join(" ")} <span class="st-when">Service date ${ui.esc(ui.fmt.day(state.serviceDate))} · all subway lines${tw} · source line_day_metrics (board_data.json latest_day)</span>`
    : "";
  if (window.__lanternCheckPin) requestAnimationFrame(window.__lanternCheckPin);
}
function setupFilterStrip() {
  if (!SCROLL) return;
  // Short screens (e.g. 1366x594 laptops): pin the strip from the start so Dates is visible, but only
  // while it leaves the headline figures uncovered; otherwise it appears once the statement scrolls away.
  const strip = $("#filterstrip"), st = $("#statement");
  let pin = false;
  const checkPin = () => {
    const h = strip ? strip.getBoundingClientRect().height : 0;
    const txt = $("#st-sub") || st, bottom = (txt.getBoundingClientRect().bottom || 0) + scrollY;
    pin = innerHeight <= 720 && h > 0 && bottom <= innerHeight - h - 4;
    document.body.classList.toggle("pin-filters", pin);
    document.body.style.setProperty("--fs-h", `${Math.ceil(h)}px`); // measured strip height = bottom padding while pinned
    if (pin) document.body.classList.add("show-filters");
  };
  checkPin(); window.__lanternCheckPin = checkPin;
  if (strip && "ResizeObserver" in window) new ResizeObserver(() => checkPin()).observe(strip);
  addEventListener("resize", checkPin, { passive: true });
  setTimeout(checkPin, 1200); // statement text lands after board_data
  const io = new IntersectionObserver(([e]) => {
    const past = !e.isIntersecting && e.boundingClientRect.top < 0;
    document.body.classList.toggle("show-filters", pin || past);
  }, { threshold: 0 });
  io.observe($("#statement"));
}

// Freedom Trail plate: the 16 sites in order (waiting until the dbt build's file is listed in board_data.json).
async function renderFtPlate() {
  const box = $("#ft-list");
  if (!box) return;
  if (!store.has("freedomTrail")) { box.innerHTML = `<p class="ch-wait">${ui.esc("Waiting for the checked data")}</p>`; return; }
  if (!ftSites && window.__lanternStartMarts) await window.__lanternStartMarts();
  if (!ftSites) { const rows = await store.run("freedomTrail"); ftSites = (rows || []).map(ftRow); }
  box.innerHTML = ui.renderSiteList(ftSites, bmap.lineColors);
  box.onclick = async (e) => {
    const b = e.target.closest("[data-site]");
    if (!b) return;
    if (!state.ftOn) await setFreedomTrail(true);
    showSite(ftSites.find((x) => String(x.order) === b.dataset.site));
  };
}

function showSite(site) {
  if (!site) return;
  state.selected = { type: "site", id: String(site.order) };
  bmap.select({});
  bmap.markStation(site.stopId || null); // highlight the nearest station, nothing else
  ui.renderSiteDetail(site, bmap.lineColors);
  openDrawer("detail");
  $("#drawer-title").textContent = DRAWER_TITLES.site;
}

// ---------------------------------------------------------------- main number (measured train delay)
const heroTile = () => (board && Array.isArray(board.tiles) ? board.tiles.filter((t) => t && t.id === HERO.tile) : []).length === 1
  ? board.tiles.find((t) => t.id === HERO.tile) : null;
// Gate-entry reconciliation (tiles[id=rider_time_lost]): all entries = entries at hours with recorded
// trains + entries at hours with no recorded trains. Whole entries, like every count on the board.
function renderGateRecon() {
  const el = $("#rider-recon");
  const t = board && Array.isArray(board.tiles) ? board.tiles.find((x) => x && x.id === "rider_time_lost") : null;
  const ok = t && [t.gated_entries_all_cells, t.gated_entries, t.gated_entries_no_trains].every(Number.isFinite);
  el.hidden = false;
  el.textContent = ok
    ? `Average weekday gate entries: ${ui.fmt.int(t.gated_entries_all_cells)} = ${ui.fmt.int(t.gated_entries)} at hours with recorded trains + ${ui.fmt.int(t.gated_entries_no_trains)} entries at hours with no recorded trains${throughText("gated_entries", "gate entries") ? ` (${throughText("gated_entries", "gate entries")})` : ""}.`
    : "Gate-entry total: Waiting for the checked figure";
}
function renderMainNumber() {
  renderGateRecon();
  const tile = heroTile();
  // Latest-day and Saturday/Sunday views have no published whole-window figure: say so, don't guess.
  const basis = state.dayType === "weekday" ? "weekday" : state.dayType === "all" ? "all" : null;
  ui.renderHero(tile, { basis });
}
// the dbt build's *_label fields cross-check duration.js once per load (console warning on any mismatch).
function crossCheckHeroLabels() {
  const tile = heroTile();
  if (!tile) return;
  for (const F of [HERO.weekday, HERO.all]) for (const k of ["total", "net", "perRun", "netPerRun"]) {
    const v = tile[F[k]], lab = tile[F[`${k}Label`]];
    if (typeof v !== "number" || typeof lab !== "string") continue;
    const mine = formatDuration(v);
    if (mine.replace(/\s+/g, " ") !== lab.replace(/\s+/g, " ")) console.warn(`[board] label mismatch ${F[k]}: duration.js "${mine}" vs board_data "${lab}"`);
  }
}
async function loadDelaySpark() {
  const rows = store.has(HERO.daily.table) ? await store.run("trainDelaySeries", {}) : null;
  ui.renderDelaySpark(rows);
}

// ---------------------------------------------------------------- service day label + insight cards
async function loadServiceDate() {
  const latest = SERVICE_DATE.latestJson && getPath(board, SERVICE_DATE.latestJson);
  const path = latest ? SERVICE_DATE.latestJson : SERVICE_DATE.json;
  const d = serviceDayLabel(getPath(board, path));
  if (d) { state.serviceDate = d.day; state.serviceDateSource = `board_data.json ${path}`; }
  // Cross-check only: the latest service_date in line_daily. Never used in place of the meta value.
  if (store.ready && store.has("lineDaily") && SERVICE_DATE.crossCheck) {
    const rows = await store.query(SERVICE_DATE.crossCheck.query.replace(/\{(\w+)\}/g, (_, k) => TABLES[k] || k));
    const c = serviceDayLabel(rows && rows[0] && rows[0].v);
    if (d && c && c.day !== d.day) console.warn(`[board] service date mismatch: ${SERVICE_DATE.json} = ${d.day}, max(service_date) in line_daily = ${c.day}`);
    if (!d) console.warn(`[board] ${SERVICE_DATE.json} missing; the latest-day view stays off.`);
  }
}

// Recomputed at view time (and every minute): "Yesterday" flips to the date after midnight ET.
function updateDayLabel() {
  const d = serviceDayLabel(state.serviceDate);
  const changed = JSON.stringify(d) !== JSON.stringify(state.day);
  state.day = d;
  const el = $("#latest");
  el.hidden = !d;
  if (d) {
    const thr = el.dataset.through;
    const dd = ui.fmt.day(d.day);
    el.textContent = `Subway data through ${thr ? ui.fmt.day(thr) : dd} · latest day ${d.label === dd || d.label.includes(dd) ? d.label : `${d.label}, ${dd}`}`;
    el.title = `Service date ${d.day}; source: ${state.serviceDateSource}`;
  }
  if (changed) {
    renderDayControl();
    renderCards({ force: true });
    renderStatement();
  }
}

function renderDayControl() {
  if (state.dayType === "latest" && !state.day) state.dayType = "all";
  ui.renderSeg($("#day-types"), dayItems(), state.dayType, onDay);
}
function onDay(id) {
  state.dayType = id;
  renderDayControl();
  scheduleRefresh();
}

function renderDateChip() {
  const chip = $("#date-chip");
  if (!state.dateBounds) return;
  chip.disabled = false;
  chip.textContent = isLatest() ? `${ui.fmt.day(state.serviceDate)} · ${state.day ? state.day.label : ""}` : `${ui.fmt.day(state.dateFrom)} – ${ui.fmt.day(state.dateTo)}`;
  chip.classList.toggle("is-narrowed", !fullWindow());
}

const cardResults = new Map(); // id -> { ok, tokens, top, focus, variant, missing }
let cardSeq = 0;
const cardMode = () => (isLatest() ? "day" : "window");
function windowText() {
  const w = board && board[BOARD_KEYS.meta] && board[BOARD_KEYS.meta][BOARD_KEYS.meta_window];
  return w && w.first && w.last ? `${ui.fmt.day(w.first)} – ${ui.fmt.day(w.last)}` : "";
}

let cardsKey = null;
async function renderCards({ force = false } = {}) {
  const box = $("#cards");
  if (!board && !store.ready) { box.innerHTML = ""; return; }
  const mode = cardMode();
  // Card figures don't follow the line/day/time filters; re-resolve only when the view changes.
  const key = `${mode}|${state.serviceDate}|${store.ready}`;
  if (!force && key === cardsKey) { drawCards(); return; }
  cardsKey = key;
  const seq = ++cardSeq;
  const w = (board && board.meta && board.meta.service_date_window) || {};
  const ctx = { board, store, serviceDate: state.serviceDate, windowFirst: w.first, windowLast: w.last };
  const results = await Promise.all(INSIGHT_CARDS.map(async (card) => {
    const variant = mode === "day" ? card.day || null : card;
    if (!variant) return [card.id, { ok: false, variant: null, tokens: {}, missing: ["(no latest-day variant)"] }];
    const r = await resolveTokens(variant, ctx);
    const vis = variant.visual || card.visual || {};
    let top = null;
    if (vis.type === "top10") {
      top = await loadTopList(vis, ctx);
      if (!top) { r.ok = false; r.missing.push(`top10:${vis.metric}`); }
    }
    const fspec = variant.focus || card.focus;
    const focus = r.ok
      ? fspec && fspec.segments === "top10"
        ? (top ? { lines: [], segments: top.map((t) => t.segment_id), stations: [], note: fspec.note || "" } : null)
        : await resolveFocus(fspec, ctx)
      : null;
    return [card.id, { ...r, variant: { ...card, ...variant, visual: vis }, top, focus }];
  }));
  if (seq !== cardSeq) return;
  cardResults.clear();
  for (const [id, r] of results) cardResults.set(id, r);
  if (state.cardSel && !(cardResults.get(state.cardSel) || {}).focus) { state.cardSel = null; bmap && bmap.setFocus(null); }
  drawCards();
}

function drawCards() {
  const opts = { day: state.day, windowText: windowText(), lineColors: (bmap && bmap.lineColors) || {}, selected: state.cardSel, mode: cardMode() };
  $("#cards").innerHTML = INSIGHT_CARDS.map((c) => cardHtml(c, cardResults.get(c.id) || { ok: false, tokens: {} }, opts)).join("");
  // The panel's height changes with its cards (phones: the strip sits under the map); refit
  // unless the reader moved the map or a card focus owns the view.
  if (bmap && !state.cardSel) requestAnimationFrame(() => bmap.refit());
}

function toggleCard(id) {
  const r = cardResults.get(id);
  if (!r || !r.focus) return;
  const next = state.cardSel === id ? null : id;
  state.cardSel = next;
  if (next && state.selected) { state.selected = null; bmap.select({}); ui.clearDetail(); if ($("#drawer").dataset.mode === "detail") openDrawer(null); }
  drawCards();
  if (next) showMapPlate();
  bmap.setFocus(next ? r.focus : null);
  const el = next && $(`#cards [data-card="${next}"]`);
  if (el) { el.focus({ preventScroll: true }); el.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "smooth" }); }
}

function setupCards() {
  const box = $("#cards");
  box.addEventListener("click", (e) => {
    const row = e.target.closest(".row[data-segment]");
    if (row) { showSegment(row.dataset.segment, { focus: true }); return; }
    if (e.target.closest(".dur")) return; // exact seconds tap
    const card = e.target.closest(".icard[data-card]");
    if (card) toggleCard(card.dataset.card);
  });
  box.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" && e.key !== " ") return;
    const card = e.target.closest(".icard[data-card]");
    if (!card || e.target !== card) return;
    e.preventDefault();
    toggleCard(card.dataset.card);
  });
  $("#date-chip").disabled = false;
  $("#date-chip").addEventListener("click", () => {
    if (!state.dateBounds) { const c = $("#date-chip"); c.classList.add("is-loading"); c.textContent = "Loading dates…"; c.setAttribute("aria-busy", "true");
      if (window.__lanternStartMarts) window.__lanternStartMarts().then(() => { c.classList.remove("is-loading"); c.removeAttribute("aria-busy"); if (!state.dateBounds) c.textContent = "Dates unavailable"; else { renderDateChip(); $("#dates").hidden = false; c.setAttribute("aria-expanded", "true"); } });
      return; }
    const d = $("#dates");
    d.hidden = !d.hidden;
    $("#date-chip").setAttribute("aria-expanded", String(!d.hidden));
  });
  $("#more").addEventListener("toggle", () => { if (bmap) setTimeout(() => bmap.refit(), 50); });
}

// ---------------------------------------------------------------- time of day
function boardPeriods() {
  const src = board && ((board[BOARD_KEYS.map] && board[BOARD_KEYS.map][BOARD_KEYS.periods]) || board[BOARD_KEYS.periods]);
  if (!Array.isArray(src) || !src.length) return null;
  return src.map((p) => ({
    service_period_id: p.service_period_id,
    service_period_name: p.service_period_name ?? p.name,
    start_minute: p.start_minute,
    end_minute: p.end_minute,
    sort_order: p.sort_order,
  }));
}

function renderStrip() {
  const focused = document.activeElement && document.activeElement.closest && document.activeElement.closest("#tod-strip")
    ? document.activeElement.dataset.period : undefined;
  ui.renderStrip(state.segs, state.periodId);
  if (focused !== undefined) {
    const el = $(`#tod-strip [data-period="${focused}"]`);
    if (el) el.focus();
  }
}

function selectPeriod(id) {
  const next = id || null;
  if (next === state.periodId) return;
  state.periodId = next;
  renderStrip();
  scheduleRefresh();
}

function setupStrip(periods) {
  if (!periods || !periods.length) return;
  state.segs = ui.layoutPeriods(periods);
  $("#tod-empty").hidden = true;
  renderStrip();
  const strip = $("#tod-strip");

  // Click / Enter / Space: each segment is a real button.
  strip.addEventListener("click", (e) => {
    const b = e.target.closest(".tod-seg");
    if (b) selectPeriod(b.dataset.period);
  });
  // Arrow keys move along the strip.
  strip.addEventListener("keydown", (e) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) return;
    const btns = [...strip.querySelectorAll(".tod-seg")];
    const i = btns.indexOf(document.activeElement);
    if (i < 0) return;
    e.preventDefault();
    const j = e.key === "Home" ? 0 : e.key === "End" ? btns.length - 1 : Math.max(0, Math.min(btns.length - 1, i + (e.key === "ArrowRight" ? 1 : -1)));
    btns[j].focus();
    selectPeriod(btns[j].dataset.period);
  });
  // Drag across the strip to scrub (pointer). Clicks still work: scrubbing starts after a few px.
  let drag = null;
  strip.addEventListener("pointerdown", (e) => { drag = { x: e.clientX, active: false }; });
  addEventListener("pointermove", (e) => {
    if (!drag) return;
    if (!drag.active && Math.abs(e.clientX - drag.x) < 5) return;
    drag.active = true;
    const r = strip.getBoundingClientRect();
    const el = document.elementFromPoint(Math.max(r.left + 1, Math.min(r.right - 1, e.clientX)), r.top + r.height / 2);
    const b = el && el.closest && el.closest(".tod-seg");
    if (b && b.dataset.period) selectPeriod(b.dataset.period);
  });
  addEventListener("pointerup", () => { drag = null; });
}

async function setupDates() {
  if (!store.has("lineDaily")) return;
  const rows = await store.run("dateRange");
  const r = rows && rows[0];
  if (!r || !r.min_date || !r.max_date) return;
  for (const id of ["date-from", "date-to"]) {
    const el = $(`#${id}`);
    el.min = r.min_date;
    el.max = r.max_date;
    el.disabled = false;
  }
  state.dateBounds = { min: r.min_date, max: r.max_date };
  state.dateFrom = r.min_date;
  state.dateTo = r.max_date;
  $("#date-from").value = r.min_date;
  $("#date-to").value = r.max_date;
  const onDate = () => {
    let a = $("#date-from").value || r.min_date;
    let b = $("#date-to").value || r.max_date;
    if (a > b) [a, b] = [b, a];
    state.dateFrom = a;
    state.dateTo = b;
    if (state.dayType === "latest") { state.dayType = "all"; renderDayControl(); } // a picked range replaces the single day
    if (state.xf && state.xf.kind === "date") state.xf = null; // a typed date replaces the chart's pick
    $("#date-from").value = a;
    $("#date-to").value = b;
    scheduleRefresh();
  };
  $("#date-from").addEventListener("change", onDate);
  $("#date-to").addEventListener("change", onDate);
}

// ---------------------------------------------------------------- selection
function trainsAtStation(stationId) {
  return state.vehicles.filter((v) => v.stationId === stationId && (v.status === "STOPPED_AT" || v.status === "INCOMING_AT"));
}

async function showStation(id, open = true) {
  const st = net && net.stations.get(id);
  if (!st) return;
  state.selected = { type: "station", id };
  if (open) { writeUrl(); drawCharts(); }
  bmap.select({ stationId: id });
  if (open) openDrawer("detail");
  const f = { ...filters(), stationId: id };
  const ok = store.has("stationDaily", "station", "periods");
  const loading = !ok && !store.tried && !!window.__lanternStartMarts;
  if (loading) window.__lanternStartMarts().finally(() => { store.tried = true; if (state.selected && state.selected.id === id) showStation(id, false); });
  const [rows, exp, tl, trend] = await Promise.all([
    ok ? store.run("stationDetail", f) : null,
    ok ? store.run("stationExposure", f) : null,
    store.has("stationTimeLost") ? store.run("stationTimeLost", f) : null,
    store.has("stationTrend") ? store.run("stationTrend", f) : null,
  ]);
  if (!state.selected || state.selected.id !== id) return;
  ui.renderStationDetail(st, {
    lineColors: bmap.lineColors,
    trains: trainsAtStation(id),
    net,
    rows,
    exposure: exp && exp[0],
    hasData: ok,
    loading,
    scope: [dateText(), dayLabel()].filter(Boolean).join(" · "),
    riderDay: riderDayLabel(),
    noGate: noGate.has(id),
    timeLost: tl && tl[0],
    trend,
  });
}

// ---------------------------------------------------------------- track stretches
async function showSegment(id, { focus = false } = {}) {
  const sg = bmap.segments.get(id);
  if (!sg) return;
  state.selected = { type: "segment", id };
  bmap.select({ segmentId: id });
  openDrawer("detail");
  if (focus) setTimeout(() => bmap.focus({ segmentId: id }), 60);
  const [rows, lb] = await Promise.all([
    store.has("segments") ? store.run("segmentDetail", { segmentId: id }) : null,
    store.has("lineBuffer") ? store.run("lineBuffer", { lineId: sg.line_id }) : null,
  ]);
  if (!state.selected || state.selected.id !== id) return;
  ui.renderSegmentDetail(rows && rows[0], { lineColors: bmap.lineColors, lineBuffer: lb && lb[0], net });
  renderLists();
}

let weekly = null;
let segRows = null;
let worse = { segs: null, stations: null };

function topRows() {
  return (segRows || []).filter((r) => r.metric_top).sort((a, b) => a.metric_rank - b.metric_rank);
}

function renderLists() {
  const decision = board && board[BOARD_KEYS.decision];
  // Top 10 share: sum of the share column over the listed rows (exact); board_data's key cross-checks it.
  const tr = topRows();
  const topShare = tr.length && tr.every((r) => typeof r.metric_share === "number") ? tr.reduce((a, r) => a + r.metric_share, 0) : null;
  const mk = stretchMetric().topShareKey;
  const ref = mk && decision && decision.segments ? decision.segments[mk] : null;
  if (topShare != null && typeof ref === "number" && Math.abs(ref - topShare) > 5e-4) console.warn(`[board] top-10 share: sum of rows ${topShare} vs board_data ${mk} ${ref}`);
  const win = board && board[BOARD_KEYS.meta] && board[BOARD_KEYS.meta][BOARD_KEYS.meta_window];
  ui.renderTopList(topRows(), {
    lineColors: bmap.lineColors,
    topShare,
    selectedId: state.selected && state.selected.type === "segment" ? state.selected.id : null,
    scopeNote: `Whole window${win ? ` (${ui.fmt.day(win.first)} – ${ui.fmt.day(win.last)})` : ""}; date and day filters don't apply`,
  });
  ui.renderWorseList(worse.segs, worse.stations, { lineColors: bmap.lineColors, expanded: state.worseExpanded });
}

function selectTab(tab) {
  state.tab = state.tab === tab && innerWidth <= 860 ? null : tab;
  for (const b of document.querySelectorAll("#tabs [role=tab]")) {
    const on = b.dataset.tab === state.tab;
    b.setAttribute("aria-selected", String(on));
    b.tabIndex = on || (!state.tab && b.dataset.tab === "top") ? 0 : -1;
  }
  for (const t of ["top", "worse", "measures"]) $(`#panel-${t}`).hidden = state.tab !== t;
  if (bmap) setTimeout(() => bmap.refit(), 50);
}

function setupTabs() {
  const tabs = $("#tabs");
  tabs.addEventListener("click", (e) => { const b = e.target.closest("[role=tab]"); if (b) selectTab(b.dataset.tab); });
  tabs.addEventListener("keydown", (e) => {
    if (!["ArrowLeft", "ArrowRight"].includes(e.key)) return;
    const btns = [...tabs.querySelectorAll("[role=tab]")];
    const i = btns.indexOf(document.activeElement);
    const j = (i + (e.key === "ArrowRight" ? 1 : -1) + btns.length) % btns.length;
    btns[j].focus();
    selectTab(btns[j].dataset.tab);
  });
  for (const id of ["#panel-top", "#panel-worse"]) {
    $(id).addEventListener("click", (e) => {
      if (e.target.closest("#worse-more")) { state.worseExpanded = !state.worseExpanded; renderLists(); return; }
      const r = e.target.closest(".row");
      if (!r) return;
      if (innerWidth <= 860) selectTab(null); // phones: fold the list away so the map and drawer have room
      if (r.dataset.segment) showSegment(r.dataset.segment, { focus: true });
      else if (r.dataset.station) { showStation(r.dataset.station); setTimeout(() => bmap.focus({ stationId: r.dataset.station }), 60); }
    });
  }
}

async function loadRiderTime() {
  const [w, sg, ws, wst] = await Promise.all([
    store.has("rtlWeekly") ? store.run("heroWeekly") : null,
    store.has("segments") ? store.run("segments") : null,
    store.has("segments") ? store.run("worseSegments") : null,
    store.has("stationTrend") ? store.run("worseStations") : null,
  ]);
  weekly = w;
  segRows = sg;
  worse = { segs: ws, stations: wst };
  if (sg && sg.length) await bmap.setSegments(sg);
  $("#tabs").hidden = !store.ready;
  $("#legend").hidden = !(sg && sg.length);
  const sm = stretchMetric();
  const lk = $("#legend .legend-keys li");
  if (lk) lk.lastChild.textContent = `Top 10 stretches · ${sm.legend}`;
  renderLists();
}

async function showLines(open = true) {
  if (open) {
    state.selected = null;
    bmap.select({});
    openDrawer("lines");
  }
  const rows = store.has("lineDaily") ? await store.run("lineCompare", filters()) : null;
  if ($("#drawer").dataset.view !== "lines") return;
  ui.renderLineCompare(rows, {
    lineColors: bmap.lineColors,
    scope: [dateText(), dayLabel()].filter(Boolean).join(" · "),
    periodNote: state.periodId ? "Whole day: the line comparison is not split by time of day." : "",
  });
}

function showTrain(id) {
  const v = bmap.train(id);
  if (!v) return;
  state.selected = { type: "train", id };
  bmap.select({ trainId: id });
  ui.renderTrainDetail(net, v, bmap.lineColors);
  openDrawer("detail");
}

function clearSelection() {
  const hadStation = state.selected && state.selected.type === "station";
  state.selected = null;
  if (hadStation) { writeUrl(); drawCharts(); }
  bmap.select({});
  bmap.markStation(null);
  ui.clearDetail();
  if ($("#drawer").dataset.mode === "detail") openDrawer(null);
}

// ---------------------------------------------------------------- freshness chip
function tickFreshness() {
  const chip = $("#fresh");
  const text = $("#fresh-text");
  const age = live && live.lastOkAt ? Date.now() - live.lastOkAt : Infinity;
  const stale = age > CONFIG.STALE_MS;
  let label;
  switch (live ? live.state : "starting") {
    case "paused": label = "Live · paused"; break;
    case "limited": label = `Live · rate limited, retrying in ${Math.max(0, Math.ceil((live.retryAt - Date.now()) / 1000))}s`; break;
    case "error": label = `Live · retrying in ${Math.max(0, Math.ceil((live.retryAt - Date.now()) / 1000))}s`; break;
    case "live": label = state.crView
      ? `Live · subway ${state.vehicles.length} · CR ${state.crVehicles.length} · updated ${ui.fmt.ago(age)}`
      : `Live · updated ${ui.fmt.ago(age)}`; break;
    default: label = "Live · connecting";
  }
  if (live && live.lastOkAt && live.state !== "live" && live.state !== "paused") label += ` · last ${ui.fmt.ago(age)}`;
  text.textContent = label;
  chip.classList.toggle("is-stale", stale || !live || live.state !== "live");
  chip.classList.toggle("is-alert", !!live && live.state === "limited");
}

// ---------------------------------------------------------------- boot
// No WebGL (old device, blocked GPU): keep every figure and chart, replace the map with a note.
function hasWebGL() {
  try { const c = document.createElement("canvas"); return !!(c.getContext("webgl2") || c.getContext("webgl")); } catch { return false; }
}
function makeMap(el, opts) {
  if (hasWebGL() && window.maplibregl) { try { return new BoardMap(el, opts); } catch (err) { console.warn("[map] unavailable", err); } }
  el.classList.add("map-off");
  const p = document.createElement("p"); p.className = "map-off-note";
  p.textContent = "The map needs WebGL, which this browser has turned off. Every figure and chart below still works.";
  el.append(p);
  const colors = Object.fromEntries(LINES.map((l) => [l.line_id, l.fallbackColor]));
  colors[COMMUTER_RAIL.LINE_ID] = COMMUTER_RAIL.FALLBACK_COLOR;
  const target = { lineColors: colors, trains: new Map(), train: () => null };
  return new Proxy(target, { get: (t, k) => (k in t ? t[k] : () => undefined) });
}

// "Data through" date: the dbt build's board_data field when it lands (meta.data_through), else meta.service_date.
// Incomplete-data warning only where his completeness flag is false (meta.data_complete / latest_day.is_complete).
// Each source's own date (dbt: meta.data_through.{subway, gated_entries, cr_reliability, cr_boardings, survey}).
// Never typed in; a missing date shows nothing rather than borrowing another source's.
export function sourceThrough(key) {
  const dt = getPath(board, "meta.data_through");
  const v = dt && typeof dt === "object" ? dt[key] : key === "subway" && typeof dt === "string" ? dt : null;
  return typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null;
}
window.__lanternThrough = sourceThrough;
function renderDataThrough() {
  const el = $("#latest");
  const through = sourceThrough("subway") || getPath(board, "latest_day.service_date") || getPath(board, "meta.service_date");
  let w = $("#data-warn");
  if (!w) { w = document.createElement("p"); w.id = "data-warn"; w.className = "data-warn"; w.setAttribute("role", "status"); $("#statement").prepend(w); }
  // Per-line low completeness on the latest day (latest_day.scopes[].is_low_completeness; rule in latest_day.completeness_rule).
  const ld = getPath(board, "latest_day.service_date");
  const low = (getPath(board, "latest_day.scopes") || []).filter((s) => s && s.is_low_completeness === true && s.scope_id !== "system");
  w.hidden = !low.length;
  w.textContent = low.length && ld ? `Incomplete data on ${ui.fmt.day(ld)} for ${low.map((s) => `${s.scope_name || s.scope_id} (${Math.round(s.completeness_share * 100)}% of scheduled trips compared)`).join(", ")}: figures for ${low.length === 1 ? "that line" : "those lines"} may be missing runs. ${getPath(board, "latest_day.completeness_rule") || ""}` : "";
  if (el && through) el.dataset.through = through;
}

async function afterMarts(ok) {
  console.info(`[data] marts ${ok ? "ready: " + [...store.tables].join(", ") : "not available"}`);
  if (!ok && !board) $("#rail-empty").hidden = false;
  if (ok) {
    let periods = null;
    if (store.has("periods")) periods = await store.run("periodList");
    if (!periods || !periods.length) periods = boardPeriods();
    setupStrip(periods);
    await setupDates();
    await loadServiceDate();
    updateDayLabel();
    setInterval(updateDayLabel, 60000);
    await loadRiderTime();
    crossCheckHeroLabels();
    loadDelaySpark();
    renderStatement();
    renderFtPlate();
    answerMyLine(myRoute);
  } else {
    for (const t of ["top", "worse", "measures"]) $(`#panel-${t}`).hidden = true;
  }
  if (ok) {
    loadCommuterRailNetwork().catch((err) => console.warn("[network] Commuter Rail shapes unavailable", err));
    try { await applyRouteColors(net, store); } catch (err) { console.warn("[network] route colours from routes.parquet unavailable; using fallbacks", err); }
    if (location.search) applyUrl();
  }
  await refresh();
  drawCharts && drawCharts();
}

async function boot() {
  // Weak device or Save-Data: solid fills instead of backdrop blur.
  const weak = (navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 2) || (navigator.deviceMemory && navigator.deviceMemory <= 2) || (navigator.connection && navigator.connection.saveData);
  if (weak) document.body.classList.add("no-glass");
  ui.setBrand();
  trackSizes();
  openDrawer(null);
  ui.renderKpis(null);
  ui.renderBuild(null);
  ui.bindDurationTips();
  setupTabs();
  selectTab(innerWidth <= 860 ? null : "top");

  bmap = makeMap($("#map"), {
    onTrainHover: (id, pt) => {
      const v = id && bmap.train(id);
      if (v) ui.showTip(ui.trainTip(net, v, bmap.lineColors), pt);
      else ui.hideTip();
    },
    onStationHover: (id, pt) => {
      const st = id && net && net.stations.get(id);
      if (st) ui.showTip(ui.stationTip(st, bmap.lineColors), pt);
      else ui.hideTip();
    },
    onTrainClick: (id) => { ui.hideTip(); showTrain(id); },
    onStationClick: (id) => { ui.hideTip(); showStation(id); },
    onSegmentHover: (id, pt) => {
      const sg = id && bmap.segments.get(id);
      if (sg) ui.showTip(ui.segmentTip(sg, bmap.lineColors), pt);
      else ui.hideTip();
    },
    onSegmentClick: (id) => { ui.hideTip(); showSegment(id); },
    onBackgroundClick: () => { ui.hideTip(); if (state.selected) clearSelection(); },
    onSiteHover: (site, pt) => { if (site) ui.showTip(ui.siteTip(site, bmap.lineColors), pt); else ui.hideTip(); },
    onSiteClick: (site) => { ui.hideTip(); showSite(site); },
  });
  setupCharts();
  setupFilterStrip();
  $("#ft-toggle").addEventListener("click", () => setFreedomTrail(!state.ftOn));

  renderDayControl();
  setupCards();

  if (!SCROLL) $("#open-build").addEventListener("click", () => {
    const d = $("#drawer");
    const showingBuild = document.body.classList.contains("drawer-open") && d.dataset.mode === "build";
    if (showingBuild) { openDrawer(null); return; }
    state.selected = null;
    bmap.select({});
    ui.clearDetail();
    openDrawer("build");
  });
  $("#open-lines").addEventListener("click", () => {
    if ($("#drawer").dataset.view === "lines" && document.body.classList.contains("drawer-open")) { openDrawer(null); ui.clearDetail(); return; }
    showLines(true);
  });
  $("#drawer-close").addEventListener("click", () => {
    state.selected = null;
    bmap.select({});
    ui.clearDetail();
    openDrawer(null);
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      state.selected = null; bmap.select({}); bmap.markStation(null); ui.clearDetail(); openDrawer(null);
      if (state.cardSel) { state.cardSel = null; drawCards(); bmap.setFocus(null); }
      if (state.xf) setCross(null);
    }
  });

  board = await loadBoardData();
  if (board) $("#rail-empty").hidden = true; // board_data.json is the build's output: it exists, so the build ran
  loadJson("health.json").then((h) => {
    ui.setHealth(h);
    if (!(board && board[BOARD_KEYS.build])) ui.renderBuild(board);
    const r = h && Array.isArray(h.runs) && h.runs[0], box = $("#rail-empty");
    if (!r || !box) return;
    if (r.status === "pass") { box.hidden = true; return; }
    box.hidden = false;
    box.querySelector(".empty-title").textContent = "The last dbt build failed";
    box.querySelector(".empty-copy").textContent = (Number.isFinite(r.nodes_failed) && Number.isFinite(r.nodes_run) ? `${r.nodes_failed.toLocaleString("en-US")} of ${r.nodes_run.toLocaleString("en-US")} nodes failed. ` : "") + "The figures shown are from the last build that passed.";
  }).catch(() => {});
  setSourceDates(getPath(board, "meta.data_through"));
  const b0 = board && board[BOARD_KEYS.build];
  const results = b0 && !Number.isFinite(b0[BOARD_KEYS.build_passed]) ? await loadJson(EXTRA_FILES.buildResults) : null;
  ui.renderBuild(board, results);
  ui.applyBoardMeta(board);
  const cov = board && board[BOARD_KEYS.coverage] && board[BOARD_KEYS.coverage][BOARD_KEYS.cov_noGates];
  noGate = new Set(cov && Array.isArray(cov.station_ids) ? cov.station_ids : []);
  bmap.setNoGate(noGate);

  // First screen from board_data.json alone (no DuckDB needed): the day label, "Data through" and the statement.
  { const d0 = serviceDayLabel(getPath(board, SERVICE_DATE.latestJson) || getPath(board, SERVICE_DATE.json)); if (d0) { state.serviceDate = d0.day; state.day = d0; renderStatement(); } }
  renderDataThrough();
  if (state.day) { const d1 = state.day; state.day = null; state.serviceDate = d1.day; updateDayLabel(); }
  renderMethods();
  setupMyLine();
  answerMyLine("Red");
  // DuckDB-WASM (~34 MB wasm) is never part of first paint: it starts when the cards/charts near the
  // viewport, on the first filter interaction, or when the URL already carries filters.
  let martsReady = null;
  const startMarts = () => {
    if (martsReady) return martsReady;
    martsReady = store.init(board).then(async (ok) => { await afterMarts(ok); return ok; }).catch((err) => { console.warn("[data] marts failed", err); return false; });
    return martsReady;
  };
  // Vendor cache (sw.js): secure contexts only; failure is harmless.
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("./sw.js", { scope: "./" }).catch(() => {});
  window.__lanternStartMarts = startMarts; // internal hook for lazy paths (charts, Freedom Trail, CR)
  // Watch only after the reader scrolls: while the first screen lays out, empty containers sit
  // briefly near the fold and would start the download on first paint.
  const nearIo = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) { nearIo.disconnect(); startMarts(); } }, { rootMargin: "400px 0px" });
  const armNear = () => { removeEventListener("scroll", armNear); for (const sel of ["#cards", "#charts"]) { const el = $(sel); if (el) nearIo.observe(el); } };
  addEventListener("scroll", armNear, { passive: true });
  const inView = (el) => { if (!el) return false; const r = el.getBoundingClientRect(); return r.height > 0 && r.top < innerHeight && r.bottom > 0; };
  if (["#cards", "#charts"].some((s) => inView($(s)))) startMarts();
  const filterSel = "#line-chips, #strip, #day-control, #date-chip, #dates, #view-toggle, .tod-seg, .date-chip, #myline-pick, #tabs";
  const onFilter = (e) => { if (e.target.closest && e.target.closest(filterSel)) { startMarts(); document.removeEventListener("pointerdown", onFilter, true); document.removeEventListener("keydown", onFilter, true); } };
  document.addEventListener("pointerdown", onFilter, true);
  document.addEventListener("keydown", onFilter, true);

  try {
    net = await loadNetwork(board, null); // board_data map first; never waits on DuckDB
  } catch (err) {
    console.warn("[network] failed to load lines and stations", err);
    net = { source: "none", routes: new Map(), lineFeatures: [], stations: new Map(), platforms: new Map() };
  }
  // Line colours: dbt routes.parquet route_color_hex (exact GTFS values) wins over the map source.
  console.info(`[network] ${net.source}: ${net.stations.size} stations, ${net.lineFeatures.length} line paths`);
  await bmap.setNetwork(net);
  const onLine = (id) => {
    if (state.lines.has(id) && state.lines.size === 1) state.lines = new Set(LINES.map((l) => l.line_id));
    else if (state.lines.size === LINES.length) state.lines = new Set([id]);
    else if (state.lines.has(id)) state.lines.delete(id);
    else state.lines.add(id);
    ui.renderLineChips(bmap.lineColors, state.lines, onLine);
    bmap.setSelectedLines(state.lines);
    scheduleRefresh();
  };
  ui.renderLineChips(bmap.lineColors, state.lines, onLine);
  onLineChip = onLine;

  // Live trains: first poll right after the network request; 15 s cadence after that.
  live = new LiveTrains({
    onData: (vehicles) => {
      // One response, two uses: subway vehicles for the board; CR only for the CR map layer.
      state.vehicles = vehicles.filter((v) => lineOfRoute(v.routeId));
      state.crVehicles = vehicles.filter((v) => !lineOfRoute(v.routeId) && (isCommuterRail(v.routeId) || v.routeType === COMMUTER_RAIL.ROUTE_TYPE));
      bmap.setTrains(state.vehicles.concat(state.crVehicles));
      if (state.selected && state.selected.type === "train") {
        const v = state.vehicles.concat(state.crVehicles).find((x) => x.id === state.selected.id);
        if (v) ui.renderTrainDetail(net, v, bmap.lineColors);
      } else if (state.selected && state.selected.type === "station") {
        showStation(state.selected.id, false);
      }
    },
    onState: tickFreshness,
  });
  live.start();

  // Map view toggle: Subway (default) / Subway + Commuter Rail. Display only; no extra requests.
  const setView = (cr) => {
    state.crView = cr;
    for (const b of document.querySelectorAll("#view-toggle button[data-view]")) b.setAttribute("aria-pressed", String((b.dataset.view === "cr") === cr));
    bmap.setCommuterRailView(cr);
    tickFreshness();
  };
  $("#view-toggle").hidden = false;
  $("#view-toggle").addEventListener("click", (e) => { const b = e.target.closest("button[data-view]"); if (b) setView(b.dataset.view === "cr"); });
  setInterval(tickFreshness, 1000);

  setupStrip(boardPeriods());
  if (location.search) { startMarts(); }
  if (location.search) applyUrl(); else history.replaceState(null, "", location.pathname + location.search + location.hash);
  await refresh();
  bmap.refit();
}

boot().then(() => {
});
