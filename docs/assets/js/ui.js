// DOM rendering. Values only ever come from dbt output or the live feed; absent data renders "—".
import { GATE } from "./sources.js";
import { CONFIG, LINES, lineOfRoute, fallbackLineColor, COMMUTER_RAIL, isCommuterRail, stretchMetric, HERO, TERMINAL, TERMINAL_STATIONS, STRETCH_DELAY_ROWS } from "./config.js";
import { BOARD_KEYS, LAYERS } from "./queries.js";
import { statusText } from "./live.js";
import { formatDuration, durationParts, exactSeconds, durationHtml } from "./duration.js";

export { formatDuration, durationHtml };

// Duration with lining tabular numerals and small unit words; exact seconds on hover/tap.
export function durationNumHtml(seconds, { signed = false } = {}) {
  const label = formatDuration(seconds, { signed });
  if (label === "—") return '<span class="num">—</span>';
  const n = Number(seconds);
  const parts = durationParts(n);
  const sign = n < 0 ? "\u2212" : signed && label !== "0 s" ? "+" : "";
  const words = label.replace(/^[+\u2212]/, "").split(" ");
  let html = "";
  for (let i = 0; i < words.length; i += 2) {
    html += `<span class="num">${i === 0 ? sign : ""}${esc(words[i])}</span><span class="num-unit word">${esc(words[i + 1])}</span>`;
  }
  return `<span class="dur dur-num" tabindex="0" title="${esc(exactSeconds(n))}" data-exact="${esc(exactSeconds(n))}" aria-label="${esc(label)} (${esc(exactSeconds(n))})">${parts ? html : esc(label)}</span>`;
}

export const $ = (sel, root = document) => root.querySelector(sel);
export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const isNum = (v) => typeof v === "number" && Number.isFinite(v);

export const fmt = {
  pct: (v) => (isNum(v) ? [(v * 100).toFixed(1), "%"] : ["—", ""]),
  secs: (v) => (isNum(v) ? [v.toFixed(1), "s"] : ["—", ""]),
  // Signed whole seconds: "+35", "−21", "0".
  signedSecs: (v) => {
    if (!isNum(v)) return ["—", ""];
    const n = Math.round(v);
    return [n > 0 ? `+${n}` : n < 0 ? `\u2212${Math.abs(n)}` : "0", " s"];
  },
  int: (v) => (isNum(v) ? Math.round(v).toLocaleString("en-US") : "—"),
  pctText: (v, d = 1) => (isNum(v) ? `${(v * 100).toFixed(d)}%` : "—"),
  signedPct: (v) => (isNum(v) ? `${v > 0 ? "+" : v < 0 ? "\u2212" : ""}${Math.abs(v * 100).toFixed(1)}%` : "—"),
  countText: (v) => {
    if (!isNum(v)) return "—";
    if (v >= 1e6) return (v / 1e6).toFixed(2) + "M";
    if (v >= 1e4) return (v / 1e3).toFixed(1) + "k";
    return Math.round(v).toLocaleString("en-US");
  },
  count: (v) => {
    if (!isNum(v)) return ["—", ""];
    if (v >= 1e6) return [(v / 1e6).toFixed(2) + "M", ""];
    if (v >= 1e4) return [(v / 1e3).toFixed(1) + "k", ""];
    return [Math.round(v).toLocaleString("en-US"), ""];
  },
  time: (iso) => {
    if (!iso) return "—";
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return "—";
    return d.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false, timeZone: "America/New_York" }) + " ET";
  },
  dateTime: (iso) => {
    const d = new Date(iso);
    if (!iso || Number.isNaN(d.getTime())) return "—";
    return d.toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false, timeZone: "America/New_York" }) + " ET";
  },
  day: (ymd) => {
    const d = new Date(`${ymd}T12:00:00`);
    return Number.isNaN(d.getTime()) ? String(ymd) : d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  },
  clock: (minute) => {
    const m = ((minute % 1440) + 1440) % 1440;
    return `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
  },
  ago: (ms) => {
    const s = Math.max(0, Math.round(ms / 1000));
    return s < 60 ? `${s}s ago` : `${Math.floor(s / 60)}m ${s % 60}s ago`;
  },
};

export function setBrand() {
  document.title = CONFIG.TITLE;
  $('[data-bind="title"]').textContent = CONFIG.TITLE;
  $('[data-bind="subtitle"]').textContent = CONFIG.SUBTITLE;
  const repo = $("#repo-link");
  // No public repository URL configured yet: hide the link rather than point at nothing.
  if (!CONFIG.REPO_URL || CONFIG.REPO_URL === "#repo") repo.hidden = true;
  else { repo.href = CONFIG.REPO_URL; repo.textContent = CONFIG.REPO_LABEL; }
  $("#docs-link").href = CONFIG.DOCS_INDEX;
  $(".legal .disclaimer").textContent = CONFIG.DISCLAIMER;
}

// Footer and docs link from board_data.json when it has them (hard-coded text stays otherwise).
let THRESH = {}, SUBWAY_THROUGH = null;
const lateText = () => (isNum(THRESH.late_trip_seconds) ? formatDuration(THRESH.late_trip_seconds) : "the late threshold");
const gapText = () => (isNum(THRESH.long_gap_ratio) ? `${THRESH.long_gap_ratio}×` : "well over");
export function applyBoardMeta(board) {
  const meta = board && board[BOARD_KEYS.meta];
  THRESH = (meta && meta.thresholds) || {};
  const dt = meta && meta.data_through;
  SUBWAY_THROUGH = dt && typeof dt === "object" && /^\d{4}-\d{2}-\d{2}$/.test(dt.subway || "") ? dt.subway : null;
  const text = meta && typeof meta[BOARD_KEYS.meta_disclaimer] === "string" && meta[BOARD_KEYS.meta_disclaimer].trim();
  if (text) $(".legal .disclaimer").textContent = text;
  $("#docs-link").href = docsLink();
}

// "Weekday" reads lower case mid-sentence; Saturday and Sunday stay capitalised.
const dayWord = (d) => (!d || /^weekday$/i.test(d) ? "weekday" : d);

// ---------------------------------------------------------------- KPI tiles
// vals: { late_trip_share, trips_compared, avg_trip_excess_seconds, excess_share_of_scheduled,
//         long_gap_share, entries_in_long_gaps, gated_entries }
// opts: { lateMin, gapRatio, riderDay, periodNote }
export function renderKpis(vals, opts = {}) {
  const set = (key, [v, u], caption) => {
    const el = $(`.kpi[data-kpi="${key}"]`);
    el.querySelector("[data-v]").textContent = v;
    el.querySelector("[data-u]").textContent = u;
    el.classList.toggle("is-empty", v === "—");
    if (caption != null) el.querySelector(".metric-caption").textContent = caption;
  };
  const k = vals || {};
  const lateMin = isNum(opts.lateMin) ? opts.lateMin : null;
  const ratio = isNum(opts.gapRatio) ? opts.gapRatio : null;
  const day = dayWord(opts.riderDay);
  const note = opts.periodNote ? ` ${opts.periodNote}` : "";

  set("late", fmt.pct(k.late_trip_share),
    `Train runs ${lateMin ? `${lateMin}+` : "5+"} min over scheduled run time. Our measure; the MBTA's Excess Trip Time is per rider and not comparable.`);
  const lc = $('.kpi[data-kpi="late"] [data-count]');
  if (lc) lc.textContent = (isNum(k.trips_compared) && isNum(k.late_trips) ? `${fmt.countText(k.late_trips)} of ${fmt.countText(k.trips_compared)} trips compared.` : isNum(k.trips_compared) ? `Of ${fmt.countText(k.trips_compared)} trips compared.` : "") + (opts.plannedOut ? " Planned-work line-days left out." : "") + note;
  const ex = $('.kpi[data-kpi="excess"]');
  ex.querySelector("[data-metric]").innerHTML = durationNumHtml(k.avg_trip_excess_seconds, { signed: true });
  ex.classList.toggle("is-empty", !isNum(k.avg_trip_excess_seconds));
  ex.querySelector(".metric-caption").textContent =
    "Avg. time over (or under) scheduled run time, per run between compared stops" + (isNum(k.excess_share_of_scheduled) ? ` · ${fmt.signedPct(k.excess_share_of_scheduled)} of scheduled time.` : ".") + ` Source: MBTA LAMP${SUBWAY_THROUGH ? `, through ${fmt.day(SUBWAY_THROUGH)}` : ""}.` + note;
  set("gaps", fmt.pct(k.long_gap_share),
    `Train came more than ${ratio ? `${ratio}×` : "well over"} the scheduled headway after the one before.`);
  set("riders", fmt.count(k.entries_in_long_gaps),
    isNum(k.gated_entries) && isNum(k.entries_in_long_gaps) && k.gated_entries > 0
      ? `${fmt.pctText(k.entries_in_long_gaps / k.gated_entries)} of ${fmt.countText(k.gated_entries)} ${day} entries. Entries, not riders${GATE() ? `; ${GATE()}` : ""}.`
      : `Average ${day} fare-gate entries. Entries, not riders${GATE() ? `; ${GATE()}` : ""}.`);
  const rk = $('.kpi[data-kpi="riders"] .kpi-k');
  if (rk) rk.textContent = day === "weekday" ? "Gate entries in long gaps" : `${day} entries in long gaps`;
}

export function renderScope(text) {
  $("#scope").textContent = text;
}

// ---------------------------------------------------------------- chips
export function renderLineChips(lineColors, selected, onToggle) {
  const box = $("#line-chips");
  box.innerHTML = "";
  for (const l of LINES) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "chip";
    b.setAttribute("aria-pressed", String(selected.has(l.line_id)));
    b.innerHTML = `<span class="chip-dot" style="background:${esc(lineColors[l.line_id] || fallbackLineColor(l.line_id) || "#6B5B48")}"></span>${esc(l.label)}`;
    b.addEventListener("click", () => onToggle(l.line_id));
    box.appendChild(b);
  }
}

export function renderSeg(box, items, current, onPick) {
  box.innerHTML = "";
  for (const it of items) {
    const b = document.createElement("button");
    b.type = "button";
    if (it.short) {
      b.innerHTML = `<span class="lab-long">${esc(it.label)}</span><span class="lab-short" aria-hidden="true">${esc(it.short)}</span>`;
      b.setAttribute("aria-label", it.label);
    } else b.textContent = it.label;
    b.setAttribute("aria-pressed", String(it.id === current));
    b.addEventListener("click", () => onPick(it.id));
    box.appendChild(b);
  }
}

// ---------------------------------------------------------------- time-of-day strip
// Short labels so no segment clips at 390 px; full name + clock range live in the tooltip.
const SHORT = {
  sunrise: "Sunrise", early_am: "Early", am_peak: "AM", midday_base: "Midday", midday_school: "School",
  pm_peak: "PM", evening: "Eve", late_evening: "Late", night: "Night",
};
export const shortPeriod = (p) => SHORT[p.service_period_id] || String(p.service_period_name || p.service_period_id).split(" ")[0];

// periods: [{ service_period_id, service_period_name, start_minute, end_minute, sort_order, long_gap_share? }]
export function layoutPeriods(periods) {
  let offset = 0;
  return [...periods]
    .sort((a, b) => a.sort_order - b.sort_order)
    .map((p) => {
      const span = ((p.end_minute - p.start_minute + 1440) % 1440) + 1;
      const seg = { ...p, offset, span };
      offset += span;
      return seg;
    });
}

export const periodRange = (s) => `${fmt.clock(s.start_minute)}–${fmt.clock(s.end_minute + 1)}`;

// Segments are real buttons (aria-pressed). First button is "All day" (periodId null).
export function renderStrip(segs, activeId) {
  const strip = $("#tod-strip");
  strip.innerHTML = "";
  const all = document.createElement("button");
  all.type = "button";
  all.className = "tod-seg tod-all";
  all.dataset.period = "";
  all.setAttribute("aria-pressed", String(!activeId));
  all.setAttribute("aria-label", "All day");
  all.innerHTML = `<span class="tod-lab"><span class="lab-long">All day</span><span class="lab-short" aria-hidden="true">All</span></span>`;
  strip.appendChild(all);

  const vals = segs.map((s) => s.long_gap_share).filter(isNum);
  const max = vals.length ? Math.max(...vals) : 0;
  const min = vals.length ? Math.min(...vals) : 0;
  for (const s of segs) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "tod-seg";
    b.dataset.period = s.service_period_id;
    b.style.flex = `${s.span} 1 0`;
    b.setAttribute("aria-pressed", String(s.service_period_id === activeId));
    const tip = `${s.service_period_name} ${periodRange(s)}` + (isNum(s.long_gap_share) ? ` · long gaps ${fmt.pct(s.long_gap_share).join("")}` : "");
    b.title = tip;
    b.setAttribute("aria-label", tip);
    const hot = isNum(s.long_gap_share) && max > 0 && s.long_gap_share === max;
    let bar = "";
    if (isNum(s.long_gap_share) && max > 0) {
      const t = max > min ? (s.long_gap_share - min) / (max - min) : 1;
      bar = `<span class="tod-bar" style="height:${3 + Math.round(t * 12)}px"></span>`;
    }
    b.innerHTML = `<span class="tod-lab">${hot ? '<i class="hot-dot" aria-hidden="true"></i>' : ""}${esc(shortPeriod(s))}</span>${bar}`;
    strip.appendChild(b);
  }
}

// ---------------------------------------------------------------- tooltip
export function showTip(html, point) {
  const tip = $("#tip");
  if (html instanceof Node) tip.replaceChildren(html); else tip.innerHTML = html; // strings: internal, escaped templates only
  tip.hidden = false;
  const w = tip.offsetWidth, h = tip.offsetHeight;
  let x = point.x + 14, y = point.y + 14;
  if (x + w > innerWidth - 8) x = point.x - w - 14;
  if (y + h > innerHeight - 8) y = point.y - h - 14;
  tip.style.left = `${Math.max(8, x)}px`;
  tip.style.top = `${Math.max(8, y)}px`;
}
export const hideTip = () => { $("#tip").hidden = true; };

function routeLabel(net, routeId, v = null) {
  const line = lineOfRoute(routeId);
  // Commuter Rail: line name from the live response (route long_name), else the route id.
  if (!line && isCommuterRail(routeId)) return `${(v && v.routeName) || routeId.replace(/^CR-/, "")}${(v && v.routeName) ? "" : " Line"} · ${COMMUTER_RAIL.LABEL}`;
  if (!line) return routeId || "Unknown line";
  if (line.line_id === "Green" && routeId.includes("-")) return `Green Line ${routeId.split("-")[1]}`;
  return line.line_id === "Mattapan" ? "Mattapan Line" : `${line.label} Line`;
}

function destination(net, v) {
  const r = net && net.routes.get(v.routeId);
  const dests = (r && Array.isArray(r.destinations) ? r.destinations : null) || v.routeDestinations;
  const d = Array.isArray(dests) ? dests[v.directionId] : null;
  return d ? `toward ${d}` : "";
}

// Train dot colour: subway line colour (routes.parquet), CR route colour from data, else CR purple.
const trainColor = (v, lineColors) => {
  const line = lineOfRoute(v.routeId);
  if (line) return lineColors[line.line_id] || fallbackLineColor(line.line_id) || "#6B5B48";
  return lineColors[COMMUTER_RAIL.LINE_ID] || v.routeColor || COMMUTER_RAIL.FALLBACK_COLOR;
};

export function trainTip(net, v, lineColors) {
  return `
    <p class="tip-k"><i style="background:${esc(trainColor(v, lineColors))}"></i>${esc(routeLabel(net, v.routeId, v))} ${esc(destination(net, v))}</p>
    <p class="tip-t">${esc(statusText(v))}</p>
    <p class="tip-m">Updated ${esc(fmt.time(v.updatedAt))}</p>`;
}

export function stationTip(st, lineColors) {
  const dots = [...new Set([...st.routeIds].map((r) => lineOfRoute(r)?.line_id).filter(Boolean))]
    .map((id) => `<i style="background:${esc(lineColors[id])}"></i>`).join("");
  return `<p class="tip-k">${dots}Station</p><p class="tip-t">${esc(st.name)}</p>`;
}

// ---------------------------------------------------------------- Freedom Trail site (the dbt build's table)
// Straight-line distance only (never "walking distance"); the walk time is an estimate.
const siteLines = (site, lineColors) => (site.lines || []).map((id) => `<span class="line-tag"><i style="background:${esc(lineColors[id] || fallbackLineColor(id) || "#6B5B48")}"></i>${esc(id)}</span>`).join("");
const siteWalk = (site) => (isNum(site.walk) ? `About ${esc(formatDuration(site.walk))} walk` : "");
export function siteTip(site, lineColors) {
  return `<p class="tip-k">Freedom Trail · site ${esc(site.order)}</p><p class="tip-t">${esc(site.name)}</p>
    ${site.stopName ? `<p class="tip-s">Nearest T: ${esc(site.stopName)} <span class="line-tags tip-lines">${siteLines(site, lineColors)}</span>${site.distanceLabel ? `, ${esc(site.distanceLabel)} straight-line` : ""}</p>` : ""}
    ${siteWalk(site) ? `<p class="tip-s">${siteWalk(site)} <span class="est">Estimate</span></p>` : ""}
    ${site.basis ? `<p class="tip-m">${esc(site.basis)}</p>` : ""}
    ${site.note ? `<p class="tip-m">${esc(site.note)}</p>` : ""}`;
}
// Freedom Trail plate list: number, site, nearest T (straight-line), estimated walk.
export function renderSiteList(sites, lineColors) {
  if (!sites || !sites.length) return `<p class="ch-wait">Waiting for the checked data</p>`;
  return `<ol class="ft-list">${sites.map((s) => `<li><button type="button" class="ft-row" data-site="${esc(s.order)}">
    <span class="ft-n">${esc(s.order)}</span><span class="ft-name">${esc(s.name)}</span>
    <span class="ft-stop">${s.stopName ? `${esc(s.stopName)} ${siteLines(s, lineColors)}${s.distanceLabel ? ` · ${esc(s.distanceLabel)} straight-line` : ""}` : ""}${siteWalk(s) ? ` · ${siteWalk(s)} <span class="est">Estimate</span>` : ""}</span></button></li>`).join("")}</ol>`;
}
export function renderSiteDetail(site, lineColors) {
  const el = $("#detail");
  el.hidden = false;
  const src = /^https?:\/\//.test(String(site.source || "")) ? `<a class="site-src" href="${esc(site.source)}" target="_blank" rel="noopener">Source</a>` : "";
  el.innerHTML = `<p class="detail-kicker">Freedom Trail · site ${esc(site.order)}</p>
    <h3 class="detail-title">${esc(site.name)}</h3>
    ${site.stopName ? `<p class="detail-lead">Nearest T: ${esc(site.stopName)}${site.distanceLabel ? `, ${esc(site.distanceLabel)} straight-line` : ""}</p><div class="line-tags">${siteLines(site, lineColors)}</div>` : ""}
    ${siteWalk(site) ? `<p class="detail-lead">${siteWalk(site)} <span class="est">Estimate</span></p>` : ""}
    ${site.basis ? `<p class="data-note">${esc(site.basis)}</p>` : ""}
    ${site.note ? `<p class="data-note">${esc(site.note)}</p>` : ""}
    <p class="data-note">The nearest station is outlined on the map. Not part of any delay figure.</p>
    ${src}`;
}

// ---------------------------------------------------------------- drawer: details
const lineTags = (ids, lineColors) =>
  `<div class="line-tags">${ids.map((id) => `<span class="line-tag"><i style="background:${esc(lineColors[id])}"></i>${esc(id)}</span>`).join("")}</div>`;

export function renderTrainDetail(net, v, lineColors) {
  const el = $("#detail");
  el.hidden = false;
  el.innerHTML = `
    <p class="detail-kicker">Train</p>
    <h3 class="detail-title">${esc(routeLabel(net, v.routeId, v))} ${esc(destination(net, v))}</h3>
    <dl class="kv">
      <dt>Status</dt><dd>${esc(statusText(v))}</dd>
      <dt>Vehicle</dt><dd><span class="id-num">${esc(v.label || v.id)}</span></dd>
      <dt>Last update</dt><dd class="mono">${esc(fmt.time(v.updatedAt))}</dd>
    </dl>`;
}

// rows: station_daily by line x period (extra s per stop, long-gap share) + station_periods entries.
// exposure: { entries_in_long_gaps, gated_entries } on the rider-day basis.
export function renderStationDetail(st, { lineColors, trains, net, rows, exposure, hasData, loading, scope, riderDay, noGate, timeLost, trend }) {
  const el = $("#detail");
  el.hidden = false;
  const ids = [...new Set([...st.routeIds].map((r) => lineOfRoute(r)?.line_id).filter(Boolean))];
  const live = trains.length
    ? `<ul class="list">${trains.map((v) => `<li><span>${esc(routeLabel(net, v.routeId))} ${esc(destination(net, v))}<br><span class="tip-s">${esc(statusText(v))}</span></span><span class="mono">${esc(fmt.time(v.updatedAt))}</span></li>`).join("")}</ul>`
    : `<p class="empty-copy">No trains at or approaching this station right now.</p>`;
  const day = dayWord(riderDay);

  let summary = "";
  if (noGate) {
    summary = `<p class="detail-note">No gate data: this station is not in the MBTA gated-entry data, so it has no entry figures. Delay and gap figures below still come from train records.</p>`;
  } else if (exposure && isNum(exposure.entries_in_long_gaps) && isNum(exposure.gated_entries) && exposure.gated_entries > 0) {
    summary = `<div class="detail-fig"><p class="num">${esc(fmt.countText(exposure.entries_in_long_gaps))}</p><p class="detail-fig-k">of ${esc(fmt.int(exposure.gated_entries))} average ${esc(day)} gate entries (${esc(fmt.pctText(exposure.entries_in_long_gaps / exposure.gated_entries))}) happen during a long gap${GATE() ? ` (${esc(GATE())})` : ""}.</p></div>`;
  }

  if (!noGate && timeLost && isNum(timeLost.rider_time_lost_seconds)) {
    summary = `<div class="detail-fig"><p class="detail-fig-v">${durationNumHtml(timeLost.rider_time_lost_seconds)}</p><p class="detail-fig-k"><span class="est mono est-model" title="Waiting time is modelled from gate entries and assumes riders arrive at random; it is not recorded">Modelled</span> rider time lost here on an average ${esc(day)}, waiting and riding beyond the schedule (estimate${GATE() ? `; ${esc(GATE())}` : ""}).</p><p class="detail-note tl-holiday">No holiday rider weights, so no share is shown.</p></div>` + summary;
  }
  let trendHtml = "";
  const tr = (trend || []).filter((t) => isNum(t.delta_excess_seconds));
  if (tr.length) {
    const t0 = tr[0];
    trendHtml = `<p class="section-k mono">Last 2 weeks vs the 4 before</p>
      <ul class="list trend">${tr.map((t) => `<li><span>${esc(t.line_id)}${t.is_getting_worse ? ' <span class="tag-alert">Getting worse</span>' : ""}<br><span class="tip-s">${t.meets_volume_threshold ? "" : "Too few departures to judge. "}Extra time per rider ${durationHtml(t.prior_seconds, { signed: true })} → ${durationHtml(t.recent_seconds, { signed: true })}</span></span><span class="mono">${durationHtml(t.delta_excess_seconds, { signed: true })}</span></li>`).join("")}</ul>
      <p class="detail-note">${esc(fmt.day(t0.recent_from))} – ${esc(fmt.day(t0.recent_to))} compared with ${esc(fmt.day(t0.prior_from))} – ${esc(fmt.day(t0.prior_to))}.</p>`;
  }

  let hist;
  if (!hasData) {
    hist = loading ? `<div class="empty"><p class="empty-title">Loading this station's figures…</p></div>` : healthEmpty("This station's delay and entry figures could not be loaded.");
  } else if (!rows || !rows.length) {
    hist = `<p class="empty-copy">No observations for this station in the selected days.</p>`;
  } else {
    const worst = Math.max(...rows.map((r) => (isNum(r.long_gap_share) ? r.long_gap_share : -1)));
    let body = "";
    let lastLine = null;
    for (const r of rows) {
      if (ids.length > 1 && r.line_id !== lastLine) {
        body += `<tr class="grp"><td colspan="4">${esc(r.line_id)}</td></tr>`;
        lastLine = r.line_id;
      }
      const hot = r.long_gap_share === worst && worst > 0;
      body += `<tr><td>${esc(r.service_period_name || r.service_period_id)}${hot ? '<i class="hot-dot" title="Highest long-gap share at this station"></i>' : ""}</td><td>${durationHtml(r.avg_excess_travel_seconds, { signed: true })}</td><td>${esc(fmt.pctText(r.long_gap_share))}</td><td>${isNum(r.daily_entries) ? esc(fmt.countText(r.daily_entries)) : "—"}</td></tr>`;
    }
    hist = `<table class="ptable"><thead><tr><th>Period</th><th title="Average time over schedule on the run into this station">Extra</th><th title="Train came more than ${esc(gapText())} the scheduled headway after the one before">Long gaps</th><th title="Average ${esc(day)} fare-gate entries${GATE() ? `, ${esc(GATE())}` : ""}">Entries</th></tr></thead><tbody>${body}</tbody></table>`;
  }
  el.innerHTML = `
    <p class="detail-kicker">Station · <span class="mono">${esc(st.id)}</span></p>
    <h3 class="detail-title">${esc(st.name)}</h3>
    ${lineTags(ids, lineColors)}
    ${summary}
    <p class="section-k mono">Live</p>
    ${live}
    ${trendHtml}
    <p class="section-k mono">By time of day · ${esc(scope)}</p>
    ${hist}`;
}

// ---------------------------------------------------------------- drawer: line comparison
// rows from line_daily: excess_share_of_scheduled (primary), avg_trip_excess_seconds, trips_compared.
export function renderLineCompare(rows, { lineColors, scope, periodNote }) {
  const el = $("#detail");
  el.hidden = false;
  if (!rows || !rows.length) {
    el.innerHTML = `<p class="empty-copy">No line figures for the selected days.</p>`;
    return;
  }
  const top = rows.find((r) => isNum(r.excess_share_of_scheduled));
  const body = rows.map((r) => {
    const name = r.line_id === "Green" && r.route_id.includes("-") ? `Green ${r.route_id.split("-")[1]}` : r.line_id === "Mattapan" ? "Mattapan" : String(r.display_name || r.route_id).replace(/ Line$/, "");
    const hot = top && r === top && r.excess_share_of_scheduled > 0;
    return `<tr><td><i class="chip-dot" style="background:${esc(lineColors[r.line_id] || fallbackLineColor(r.line_id) || "#6B5B48")}"></i>${esc(name)}${hot ? '<i class="hot-dot" title="Furthest over schedule relative to scheduled run time"></i>' : ""}</td>
      <td>${esc(fmt.signedPct(r.excess_share_of_scheduled))}</td>
      <td class="dim">${durationHtml(r.avg_trip_excess_seconds, { signed: true })}</td>
      <td>${esc(fmt.pctText(r.late_trip_share))}</td>
      <td class="dim">${esc(fmt.int(r.trips_compared))}</td></tr>`;
  }).join("");
  el.innerHTML = `
    <p class="detail-kicker">Lines · ${esc(scope)}</p>
    <h3 class="detail-title">Time over schedule, by line</h3>
    <p class="detail-note">Ranked by extra time as a share of scheduled run time, so long and short lines compare fairly. Time per run is shown for reference.${periodNote ? ` ${esc(periodNote)}` : ""}</p>
    <table class="ptable ltable"><thead><tr><th>Line</th><th title="Extra run time as a share of scheduled run time">Over sched.</th><th title="Average time over schedule per run">Per run</th><th title="Runs finishing more than ${esc(lateText())} over schedule">Late</th><th title="Runs compared to the schedule">Runs</th></tr></thead><tbody>${body}</tbody></table>`;
}

export function clearDetail() {
  const el = $("#detail");
  el.hidden = true;
  el.innerHTML = "";
}

// ---------------------------------------------------------------- drawer: how it's built
// dbt docs index comes from build.docs.index ("dbt/index.html"), served next to the board.
let DOCS_INDEX = CONFIG.DOCS_INDEX;
const docsLink = (anchor = "") => `${DOCS_INDEX}${anchor || ""}`;

// Totals straight from dbt: build.passed/warned/errored, else counted from build_results.json.
function buildTotals(b, results) {
  const K = BOARD_KEYS;
  if (isNum(b[K.build_passed])) return { passed: b[K.build_passed], warned: b[K.build_warned], errored: b[K.build_errored], total: b[K.build_nodesTotal] };
  if (Array.isArray(results) && results.length) {
    const n = (st) => results.filter((r) => st.includes(r.status)).length;
    return { passed: n(["pass", "success"]), warned: n(["warn"]), errored: n(["error", "fail", "runtime error"]), total: results.length };
  }
  return { passed: null, warned: null, errored: null, total: null };
}

// Last dbt build, from data/health.json (runs[0] is newest). Never shows a stale "waiting" box.
let HEALTH = null;
export function setHealth(h) { HEALTH = h && Array.isArray(h.runs) && h.runs.length ? h.runs[0] : null; }
function healthEmpty(what) {
  const h = HEALTH;
  if (!h) return `<div class="empty"><p class="empty-title">Build status unavailable</p><p class="empty-copy">health.json could not be read, so the last dbt build is not known.</p></div>`;
  const when = typeof h.run_at_utc === "string" ? new Date(h.run_at_utc).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" }) : "";
  if (h.status === "pass") return `<div class="empty"><p class="empty-title">Last dbt build passed${when ? ` (${esc(when)})` : ""}</p><p class="empty-copy">${isNum(h.nodes_run) ? `${esc(fmt.countText(h.nodes_run))} nodes ran, ${esc(fmt.countText(h.nodes_failed || 0))} failed. ` : ""}${esc(what)}</p></div>`;
  return `<div class="empty"><p class="empty-title">The last dbt build failed${when ? ` (${esc(when)})` : ""}</p><p class="empty-copy">${isNum(h.nodes_failed) && isNum(h.nodes_run) ? `${esc(fmt.countText(h.nodes_failed))} of ${esc(fmt.countText(h.nodes_run))} nodes failed. ` : ""}The figures shown are from the last build that passed.</p></div>`;
}

export function renderBuild(board, results = null) {
  const body = $("#build-body");
  const b = board && board[BOARD_KEYS.build];
  if (!b) {
    body.innerHTML = healthEmpty("Model counts and test results were not in board_data.json.");
    return;
  }
  const K = BOARD_KEYS;
  const docs = b[K.build_docs] || {};
  if (typeof docs.index === "string" && docs.index) DOCS_INDEX = /^(\.|\/|https?:)/.test(docs.index) ? docs.index : `./${docs.index}`;
  const counts = { ...(b[K.build_modelsByLayer] || {}) };
  if (isNum(b[K.build_sources])) counts.raw = b[K.build_sources];
  const lineage = docsLink(docs.lineage_anchor || docs.overview_anchor || "");
  const anchors = new Map();
  for (const list of Object.values(b[K.build_models] || {})) {
    for (const m of Array.isArray(list) ? list : []) if (m && m.name && m.docs_anchor) anchors.set(m.name, m.docs_anchor);
  }
  const layerName = (x) => (x === "sources" ? "raw" : x);
  const edges = (Array.isArray(b[K.build_edges]) ? b[K.build_edges] : []).map((e) => ({ from: layerName(e.from), to: layerName(e.to), count: e.count }));
  const layers = LAYERS.filter((l) => l !== "exports" || isNum(counts.exports));
  const edge = (a, c) => edges.find((e) => e.from === a && e.to === c);

  const W = 300, H = 66, n = layers.length, gapW = 10, nodeW = (W - gapW * (n - 1)) / n;
  let svg = `<svg class="flow" viewBox="0 0 ${W} ${H}" role="img" aria-label="Layer flow: ${layers.join(" to ")}">`;
  layers.forEach((layer, i) => {
    const x = i * (nodeW + gapW);
    if (i < n - 1) {
      const e = edge(layer, layers[i + 1]);
      svg += `<line x1="${x + nodeW}" y1="${H / 2}" x2="${x + nodeW + gapW}" y2="${H / 2}" stroke="rgba(43,33,24,${e ? 0.6 : 0.18})" stroke-width="1"><title>${e && isNum(e.count) ? `${e.count} refs` : ""}</title></line>`;
    }
    const v = counts[layer];
    const node = `<rect x="${x + 0.5}" y="8.5" width="${nodeW - 1}" height="${H - 17}" rx="3" fill="rgba(248,242,228,0.6)" stroke="rgba(43,33,24,0.35)"/>
      <text x="${x + nodeW / 2}" y="31" text-anchor="middle" fill="#2B2118" style="font-family:var(--font);font-weight:600;font-size:17px;font-variant-numeric:lining-nums tabular-nums">${isNum(v) ? v : "—"}</text>
      <text x="${x + nodeW / 2}" y="46" text-anchor="middle" fill="#54453A" style="font-family:var(--font);font-size:10px;font-variant-caps:all-small-caps;letter-spacing:0.05em">${esc(layer === "intermediate" ? "interm." : layer)}</text>`;
    svg += `<a href="${esc(lineage)}" aria-label="${esc(layer)} layer in the dbt docs">${node}</a>`;
  });
  svg += "</svg>";

  // dbt build totals as dbt reports them (build block; build_results.json statuses as a fallback).
  const tot = buildTotals(b, results);
  const passed = tot.passed, warned = tot.warned, failed = tot.errored;
  const byType = b[K.build_nodesByType] || {};
  const typeName = { test: ["data test", "data tests"], model: ["model", "models"], seed: ["seed", "seeds"], snapshot: ["snapshot", "snapshots"], unit_test: ["unit test", "unit tests"] };
  const parts = Object.keys(typeName).filter((t) => isNum(byType[t])).map((t) => [byType[t], typeName[t][byType[t] === 1 ? 0 : 1]]);
  const stat = (v, k, alert) => `<div class="stat${alert ? " is-alert" : ""}"><p class="id-num">${isNum(v) ? v : "—"}</p><p class="stat-k">${esc(k)}</p></div>`;
  const tagList = (names) =>
    names.length
      ? `<p class="namelist">${names.map((nm) => (anchors.has(nm) ? `<a href="${esc(docsLink(anchors.get(nm)))}">${esc(nm)}</a>` : esc(nm))).join(' <span class="sep">·</span> ')}</p>`
      : `<p class="empty-copy">None listed.</p>`;
  const list = (k) => (Array.isArray(b[k]) ? b[k] : []);

  body.innerHTML = `
    ${svg}
    <div class="stats">
      ${stat(passed, "passed")}
      ${stat(warned, "warnings")}
      ${stat(failed, "errors", isNum(failed) && failed > 0)}
    </div>
    ${parts.length ? `<p class="build-sub mono">${parts.map(([v, k]) => `${v} ${k}`).join(" · ")}${isNum(tot.total) ? ` · ${tot.total} nodes` : ""}</p>` : ""}
    ${renderCoverage(board)}
    <p class="section-k mono">Contracted models · ${list(K.build_contracted).length}</p>
    ${tagList(list(K.build_contracted))}
    <p class="section-k mono">Incremental models</p>
    ${tagList(list(K.build_incremental))}
    <p class="build-meta"><span>Last build ${esc(fmt.dateTime(b[K.build_generatedAt]))}</span><span>dbt ${esc(b[K.build_dbtVersion] || "—")}</span><a class="repo" href="${esc(docsLink())}">dbt docs</a><a class="repo" href="${esc(lineage)}">Lineage graph</a></p>`;
  const top = $("#docs-link");
  if (top) top.href = docsLink();
}

// Data coverage from dbt mart_data_coverage (board_data.json `coverage`).
function renderCoverage(board) {
  const K = BOARD_KEYS;
  const c = board && board[K.coverage];
  if (!c) return "";
  const defs = c[K.cov_definitions] || {};
  const rows = Array.isArray(c[K.cov_byRoute]) ? c[K.cov_byRoute] : [];
  const sys = c[K.cov_system] || {};
  const ng = c[K.cov_noGates] || {};
  const name = (r) => (r.route_id.startsWith("Green-") ? `Green ${r.route_id.split("-")[1]}` : r.route_id === "Mattapan" ? "Mattapan" : String(r.display_name || r.route_id).replace(/ Line$/, ""));
  const table = rows.length
    ? `<table class="ptable ctable"><thead><tr><th>Line</th><th title="${esc(defs.no_scheduled_travel || "")}">No run time</th><th title="${esc(defs.no_scheduled_headway || "")}">No gap</th><th title="Neither a scheduled run time nor a scheduled gap">Neither</th></tr></thead><tbody>
      ${rows.map((r) => `<tr><td>${esc(name(r))}</td><td>${esc(fmt.pctText(r.share_without_scheduled_travel))}</td><td>${esc(fmt.pctText(r.share_without_scheduled_headway))}</td><td>${esc(fmt.pctText(r.share_without_any_schedule))}</td></tr>`).join("")}
      ${isNum(sys.share_without_any_schedule) ? `<tr class="tot"><td>All subway</td><td>${esc(fmt.pctText(sys.share_without_scheduled_travel))}</td><td>${esc(fmt.pctText(sys.share_without_scheduled_headway))}</td><td>${esc(fmt.pctText(sys.share_without_any_schedule))}</td></tr>` : ""}
      </tbody></table>`
    : "";
  const byLine = ng.by_line && typeof ng.by_line === "object" ? Object.entries(ng.by_line).map(([l, ids]) => `${Array.isArray(ids) ? ids.length : ids} ${l === "Mattapan" ? "Mattapan" : `${l} Line`}`) : [];
  const gates = isNum(ng.count)
    ? `<p class="detail-note">${ng.count} of ${isNum(ng.of_stations) ? ng.of_stations : "—"} stations have no gate data${byLine.length ? ` (${esc(byLine.join(", "))})` : ""}. They are drawn hollow on the map and carry no entry figures.</p>`
    : "";
  return `
    <p class="section-k mono">Data coverage · stop records without a schedule</p>
    <p class="detail-note">Share of train stop records that cannot be compared to the schedule: no scheduled run time from the previous stop, no scheduled gap since the previous train, or neither.</p>
    ${table}
    ${gates}`;
}


// ---------------------------------------------------------------- main number: measured train delay
// tile: board_data.json HERO.tile; basis: "weekday" | "all" | null (no published figure for that day type)
export function renderHero(tile, { basis } = {}) {
  $("#hero").hidden = false;
  const F = basis ? HERO[basis] : null;
  const v = (k) => (tile && F && isNum(tile[F[k]]) ? tile[F[k]] : null);
  const per = v("perRun"), netPer = v("netPerRun"), total = v("total"), net = v("net"), runs = v("runs"), days = v("days");
  const word = basis === "all" ? "day" : "weekday";
  $("#hero-k").textContent = `Train delay per run, average ${word}`;
  if (per == null || total == null) {
    $("#hero-v").innerHTML = "";
    $("#hero-v").hidden = true;
    $("#hero-s").innerHTML = `<span class="mono hero-wait">${tile ? "Published for weekdays and all days only." : "Waiting for the dbt build with measured train delay."}</span>`;
    $("#hero-note").hidden = true;
    return;
  }
  $("#hero-v").hidden = false;
  $("#hero-v").innerHTML = `${durationNumHtml(per)}<span class="num-unit word">late per run</span>${netPer != null ? `<span class="hero-net mono">${esc(formatDuration(netPer, { signed: true }))} net</span>` : ""}`;
  $("#hero-s").innerHTML = `Across ${runs != null ? `about ${esc(fmt.int(runs))} runs` : "all runs"} on an average ${word}, that adds up to ${durationHtml(total)} of train time over schedule${net != null ? ` (${durationHtml(net, { signed: true })} net of early runs)` : ""}.${days != null ? ` <span class="mono hero-days">${esc(fmt.int(days))} ${word}s.</span>` : ""}`;
  $("#hero-note").hidden = false;
  $("#hero-note").textContent = HERO.note;
}

// Daily sparkline of measured train delay (late-only solid ink, net faint ink). rows: [{ d, day_type, late, net }]
export function renderDelaySpark(rows) {
  const wrap = $("#hero-spark-wrap");
  const pts = (rows || []).filter((r) => isNum(r.late));
  if (pts.length < 2) { wrap.hidden = true; return; }
  wrap.hidden = false;
  $("#hero-spark").innerHTML = sparkSvg(pts, { x: "d", series: [{ key: "late" }, { key: "net", dim: true }] }, (r) => [
    `${fmt.day(r.d)}: ${formatDuration(r.late)} of train time over schedule, late time only`,
    `Net ${isNum(r.net) ? formatDuration(r.net, { signed: true }) : "—"} · ${r.day_type || ""} · exact ${exactSeconds(r.late)} late-only`,
  ]);
  $("#hero-spark-k").textContent = `Daily, ${fmt.day(pts[0].d)} – ${fmt.day(pts[pts.length - 1].d)} · late time only (solid), net (faint)`;
}

// Shared mini sparkline with per-point hover targets (data-tip-s / data-tip-d).
export function sparkSvg(rows, { x, series }, tipOf) {
  const W = 240, H = 34, p = 3;
  const all = series.flatMap((s) => rows.map((r) => r[s.key]).filter(isNum));
  const lo = Math.min(0, ...all), hi = Math.max(...all);
  const X = (i) => p + (i * (W - 2 * p)) / Math.max(1, rows.length - 1);
  const Y = (val) => H - p - ((val - lo) / (hi - lo || 1)) * (H - 2 * p);
  let svg = lo < 0 ? `<line x1="0" x2="${W}" y1="${Y(0).toFixed(1)}" y2="${Y(0).toFixed(1)}" stroke="rgba(43,33,24,0.25)" stroke-width="0.6" vector-effect="non-scaling-stroke"/>` : "";
  for (const s of series.slice().reverse()) {
    const pts = rows.map((r, i) => (isNum(r[s.key]) ? `${X(i).toFixed(1)},${Y(r[s.key]).toFixed(1)}` : null)).filter(Boolean).join(" ");
    svg += `<polyline points="${pts}" fill="none" stroke="${s.dim ? "rgba(43,33,24,0.38)" : "rgba(43,33,24,0.9)"}" stroke-width="1.1" vector-effect="non-scaling-stroke"/>`;
  }
  const w = (W - 2 * p) / Math.max(1, rows.length - 1);
  rows.forEach((r, i) => {
    const [a, b] = tipOf(r);
    svg += `<rect class="tip-hit" x="${(X(i) - w / 2).toFixed(1)}" y="0" width="${w.toFixed(1)}" height="${H}" fill="transparent" data-tip-s="${esc(a)}" data-tip-d="${esc(b)}"/>`;
  });
  return svg;
}

// ---------------------------------------------------------------- rider time lost (secondary, estimate)
// vals: { rider_time_lost_seconds, wait_seconds?, ride_seconds? } ; opts: { dayWord, note, keep }
export function renderRider(vals, opts = {}) {
  const card = $("#rider");
  const v = vals && vals.rider_time_lost_seconds;
  const day = dayWord(opts.dayWord || "weekday");
  $("#rider-k").textContent = `Rider time lost per ${day}`;
  if (!isNum(v)) {
    card.hidden = !opts.keep;
    $("#rider-v").innerHTML = '<span class="num is-empty">—</span>';
    $("#rider-s").textContent = opts.keep ? "No rider-time estimate for this selection." : "";
    return;
  }
  card.hidden = false;
  $("#rider-v").innerHTML = durationNumHtml(v);
  // Short line: the split, when dbt provides it (the card title already says what the total is).
  $("#rider-s").innerHTML = (isNum(vals.wait_seconds) && isNum(vals.ride_seconds)
    ? `Extra waiting ${durationHtml(vals.wait_seconds)} · extra riding ${durationHtml(vals.ride_seconds)}.` : "Waiting and riding beyond the schedule, all riders combined.") + (opts.note ? ` ${esc(opts.note)}` : "") + (GATE() ? ` Estimate from ${esc(GATE())}.` : "");
}

// weeks: [{ week_start, week_end, first_date, last_date, is_complete_week, seconds }]
export function renderSpark(weeks, { from, to, unit = "weekday" } = {}) {
  const wrap = $("#spark-wrap");
  const pts = (weeks || []).filter((w) => isNum(w.seconds));
  if (pts.length < 2) { wrap.hidden = true; return; }
  wrap.hidden = false;
  const W = 240, H = 34, pad = 3;
  const vals = pts.map((w) => w.seconds);
  const lo = Math.min(0, ...vals), hi = Math.max(...vals);
  const x = (i) => pad + (i * (W - pad * 2)) / (pts.length - 1);
  const y = (v) => H - pad - ((v - lo) / (hi - lo || 1)) * (H - pad * 2);
  const full = pts.map((w, i) => [x(i), y(w.seconds), w]).filter((p) => p[2].is_complete_week);
  let svg = "";
  // selected date range as a faint band
  if (from && to) {
    const idx = pts.map((w, i) => (w.week_end >= from && w.week_start <= to ? i : -1)).filter((i) => i >= 0);
    if (idx.length && idx.length < pts.length) svg += `<rect x="${x(idx[0]) - 3}" y="0" width="${x(idx[idx.length - 1]) - x(idx[0]) + 6}" height="${H}" fill="rgba(43,33,24,0.07)" rx="2"/>`;
  }
  if (full.length > 1) svg += `<polyline points="${full.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ")}" fill="none" stroke="rgba(43,33,24,0.75)" stroke-width="1.2" vector-effect="non-scaling-stroke"/>`;
  pts.forEach((w, i) => {
    const last = i === pts.length - 1;
    const r = last || !w.is_complete_week ? 2.2 : 1.4;
    const fill = w.is_complete_week ? "#2B2118" : "none";
    svg += `<circle cx="${x(i).toFixed(1)}" cy="${y(w.seconds).toFixed(1)}" r="${r}" fill="${fill}" stroke="#2B2118" stroke-width="0.8" vector-effect="non-scaling-stroke"><title>Week of ${fmt.day(w.week_start)}${w.is_complete_week ? "" : " (part week)"}: ${formatDuration(w.seconds)} per ${unit} (${exactSeconds(w.seconds)})</title></circle>`;
  });
  $("#spark").innerHTML = svg;
  const lastFull = [...pts].reverse().find((w) => w.is_complete_week);
  const prev = lastFull ? pts.filter((w) => w.is_complete_week && w.week_start < lastFull.week_start).slice(-4) : [];
  let txt = `By week, average ${unit}`;
  if (lastFull) {
    txt = `Last full week (${fmt.day(lastFull.week_start)}): ${formatDuration(lastFull.seconds)} ${unit === "day" ? "on an average day" : `per ${unit}`}`;
    if (prev.length) {
      const avg = prev.reduce((a, w) => a + w.seconds, 0) / prev.length;
      const d = lastFull.seconds - avg;
      txt += ` · ${d > 0 ? "more" : "less"} than the ${prev.length} weeks before`;
    }
  }
  $("#spark-k").textContent = txt;
}

// ---------------------------------------------------------------- lists
const lineDot = (lineColors, id) => `<i class="row-dot" style="background:${esc(lineColors[id] || fallbackLineColor(id) || "#6B5B48")}"></i>`;

// rows: top-10 stretches sorted by metric_rank (config STRETCH_METRIC). topShare: dbt share of the top 10.
export function renderTopList(rows, { lineColors, topShare, selectedId, scopeNote }) {
  const el = $("#panel-top");
  const m = stretchMetric();
  if (!rows || !rows.length) {
    el.innerHTML = `<p class="empty-copy panel-empty">Track stretch figures appear once dbt publishes them.</p>`;
    return;
  }
  const hasShare = rows.some((r) => isNum(r.metric_share));
  el.innerHTML = `
    <p class="panel-note">${esc(m.label)}, ${esc(m.valueNote)}. ${esc(scopeNote)}.${hasShare && m.shareNote ? ` ${esc(m.shareNote)}` : ""}</p>
    <ol class="rows">${rows.map((r) => `<li><button type="button" class="row${r.segment_id === selectedId ? " is-on" : ""}" data-segment="${esc(r.segment_id)}">
      <span class="row-rk mono">${esc(r.metric_rank)}</span>${lineDot(lineColors, r.line_id)}
      <span class="row-nm">${esc(r.segment_name)}</span>
      <span class="row-v">${durationHtml(r.metric_value)}${isNum(r.metric_net) ? `<span class="row-net mono">${esc(formatDuration(r.metric_net, { signed: true }))} net</span>` : ""}</span>
      <span class="row-sh mono">${hasShare ? esc(fmt.pctText(r.metric_share, 1)) : ""}</span></button></li>`).join("")}</ol>
    ${isNum(topShare) && m.shareOf ? `<p class="panel-note">Together these 10 stretches make up ${esc(fmt.pctText(topShare, 1))} ${esc(m.shareOf)}.</p>` : ""}`;
}

// segs/stations: getting-worse rows sorted by delta. expanded: show all.
export function renderWorseList(segs, stations, { lineColors, expanded }) {
  const el = $("#panel-worse");
  const a = segs || [], b = stations || [];
  if (!a.length && !b.length) {
    el.innerHTML = `<p class="empty-copy panel-empty">${segs || stations ? "Nothing is flagged as getting worse right now." : "Trend figures appear once dbt publishes them."}</p>`;
    return;
  }
  const w = a[0] || b[0];
  const cap = expanded ? Infinity : 5;
  const group = (title, rows, kind, unit) => rows.length ? `
    <p class="section-k mono">${esc(title)} · ${rows.length}</p>
    <ol class="rows">${rows.slice(0, cap).map((r) => `<li><button type="button" class="row" data-${kind}="${esc(kind === "segment" ? r.segment_id : r.station_id)}">
      ${lineDot(lineColors, r.line_id)}<span class="row-nm">${esc(kind === "segment" ? r.segment_name : r.station_name)}</span>
      <span class="row-v row-up">${durationHtml(r.delta_excess_seconds, { signed: true })}</span><span class="row-sh mono">${esc(unit)}</span></button></li>`).join("")}</ol>` : "";
  const more = a.length > 5 || b.length > 5;
  el.innerHTML = `
    <p class="panel-note">Extra time over schedule, last 2 weeks (${esc(fmt.day(w.recent_from))} – ${esc(fmt.day(w.recent_to))}) vs the 4 weeks before. Date and day filters don't apply.</p>
    ${group("Track stretches", a, "segment", "/ trip")}
    ${group("Stations", b, "station", "/ rider")}
    ${more ? `<button type="button" class="pill pill-sm" id="worse-more">${expanded ? "Show fewer" : "Show all"}</button>` : ""}`;
}

// ---------------------------------------------------------------- drawer: track stretch
const CAUSE = {
  schedule: ["Mostly the schedule", "Trains are slower than scheduled by about the same amount most days, so the timetable is likely too tight."],
  service: ["Mostly day-to-day service", "Run times swing a lot from day to day: some days fine, some days slow."],
  mixed: ["Both schedule and service", "Partly a tight timetable, partly day-to-day swings."],
};

export function renderSegmentDetail(sg, { lineColors, lineBuffer, net }) {
  const el = $("#detail");
  el.hidden = false;
  if (!sg) { el.innerHTML = `<p class="empty-copy">No figures for this stretch.</p>`; return; }
  const route = net && net.routes.get(sg.route_id);
  const dest = route && Array.isArray(route.destinations) ? route.destinations[sg.direction_id] : null;
  const lineName = sg.line_id === "Mattapan" ? "Mattapan Line" : `${sg.line_id} Line`;
  const m = stretchMetric();
  const rank = isNum(sg.metric_rank) ? `<p class="detail-note">${sg.metric_top ? '<i class="hot-dot" aria-hidden="true"></i> ' : ""}Rank ${sg.metric_rank} of ${isNum(sg.ranked) ? sg.ranked : "—"} ranked stretches${isNum(sg.metric_share) && sg.metric_share > 0 && m.shareOf ? `; ${esc(fmt.pctText(sg.metric_share))} ${esc(m.shareOf)}` : ""}.</p>` : "";
  const loss = isNum(sg.metric_value)
    ? `<div class="detail-fig"><p class="detail-fig-v">${durationNumHtml(sg.metric_value)}</p><p class="detail-fig-k">${esc(m.label.toLowerCase())} on this stretch, ${esc(m.valueNote)}.</p></div>${rank}`
    : `<p class="detail-note">No ${esc(m.label.toLowerCase())} figure for this stretch.</p>`;
  const term = terminalOf(sg);
  const termName = term === "start" ? sg.from_station_name : term === "end" ? sg.to_station_name : "";
  // Measured delay rows (config STRETCH_DELAY_ROWS): first present column per row.
  const colOf = (r) => r.columns.find((c) => isNum(sg[c]));
  const delayRows = STRETCH_DELAY_ROWS.filter((r) => colOf(r) && (!r.terminalOnly || (r.terminalOnly === "departure" ? term === "start" : !!term)));
  const delay = delayRows.length ? `<p class="section-k mono">Train delay (measured)</p>
      <dl class="kv">${delayRows.map((r) => `<dt>${esc(r.label.replace("{terminal}", termName || "the terminal"))}</dt><dd>${durationHtml(sg[colOf(r)], { signed: !!r.signed })}</dd>`).join("")}</dl>` : "";
  const termNote = terminalNote(sg) ? `<p class="data-note mono">${esc(terminalNote(sg))}</p>` : "";

  // typical vs bad trip
  let trip = "";
  if (isNum(sg.median_run_seconds) && isNum(sg.p90_run_seconds)) {
    trip = `<p class="section-k mono">How long the trip takes</p>
      <dl class="kv">
        ${isNum(sg.median_scheduled_run_seconds) ? `<dt>Scheduled</dt><dd>${durationHtml(sg.median_scheduled_run_seconds)}</dd>` : ""}
        <dt>Typical trip</dt><dd>${durationHtml(sg.median_run_seconds)}</dd>
        <dt>A bad trip (1 in 10)</dt><dd>${durationHtml(sg.p90_run_seconds)}</dd>
      </dl>
      ${isNum(sg.buffer_seconds) ? `<p class="detail-callout">Leave ${durationHtml(sg.buffer_seconds)} earlier than the typical trip to be on time 9 times out of 10.</p>` : ""}`;
    if (lineBuffer && isNum(lineBuffer.avg_segment_buffer_seconds)) {
      trip += `<p class="detail-note">On the ${esc(lineName)} the average stretch needs ${durationHtml(lineBuffer.avg_segment_buffer_seconds)} of extra time for that.</p>`;
    }
  }

  // trend
  let trend = "";
  if (isNum(sg.avg_excess_seconds_recent) && isNum(sg.avg_excess_seconds_prior)) {
    trend = `<p class="section-k mono">Last 2 weeks vs the 4 before</p>
      <dl class="kv">
        <dt>${esc(fmt.day(sg.prior_from))} – ${esc(fmt.day(sg.prior_to))}</dt><dd>${durationHtml(sg.avg_excess_seconds_prior, { signed: true })} per trip</dd>
        <dt>${esc(fmt.day(sg.recent_from))} – ${esc(fmt.day(sg.recent_to))}</dt><dd>${durationHtml(sg.avg_excess_seconds_recent, { signed: true })} per trip</dd>
      </dl>
      <p class="detail-note">${sg.is_getting_worse ? '<span class="tag-alert">Getting worse</span> ' : ""}${sg.meets_volume_threshold === false ? "Too few trips to judge a trend." : sg.is_getting_worse ? "Clearly slower than before." : "No clear change beyond the usual."}</p>`;
  }

  // schedule vs service (only when dbt has a verdict)
  let cause = "";
  const c = CAUSE[sg.cause_class];
  if (c) {
    cause = `<p class="section-k mono">Schedule or service</p>
      <p class="detail-lead">${esc(c[0])}</p>
      <p class="detail-note">${esc(c[1])}${isNum(sg.bias_seconds) ? ` Typical day: ${durationHtml(sg.bias_seconds, { signed: true })} vs schedule` : ""}${isNum(sg.variability_iqr_seconds) ? `, day-to-day spread ${durationHtml(sg.variability_iqr_seconds)}.` : isNum(sg.bias_seconds) ? "." : ""}</p>`;
  }

  el.innerHTML = `
    <p class="detail-kicker">Track stretch · ${esc(lineName)}</p>
    <h3 class="detail-title">${esc(sg.from_station_name)} → ${esc(sg.to_station_name)}</h3>
    <div class="line-tags"><span class="line-tag"><i style="background:${esc(lineColors[sg.line_id] || fallbackLineColor(sg.line_id) || "#6B5B48")}"></i>${esc(lineName)}${dest ? ` toward ${esc(dest)}` : ""}</span></div>
    ${loss}
    ${delay}
    ${termNote}
    ${trip}
    ${trend}
    ${cause}`;
}

// Terminal stretch: dbt flags (is_terminal_departure / is_terminal_arrival) when present; else the
// configured terminal stations. Returns "start" | "end" | null.
export function terminalOf(sg) {
  if (sg[TERMINAL.departure] != null || sg[TERMINAL.arrival] != null) return sg[TERMINAL.departure] ? "start" : sg[TERMINAL.arrival] ? "end" : null;
  if (TERMINAL_STATIONS[sg.from_station_id]) return "start";
  if (TERMINAL_STATIONS[sg.to_station_id]) return "end";
  return null;
}

// Arrival-terminal stretches whose platform wait can't be split from the run (dbt terminal_time_split).
export function terminalNote(sg) {
  if (terminalOf(sg) !== "end") return "";
  return TERMINAL.splitValues.includes(sg[TERMINAL.split]) ? "" : TERMINAL.notSplitNote;
}

export const segmentTip = (sg, lineColors) => `
  <p class="tip-k"><i style="background:${esc(lineColors[sg.line_id] || fallbackLineColor(sg.line_id) || "#6B5B48")}"></i>Track stretch${sg.metric_top ? ` · top ${esc(sg.metric_rank)}` : ""}</p>
  <p class="tip-t">${esc(sg.segment_name)}</p>
  ${isNum(sg.metric_value) ? `<p class="tip-m">${esc(formatDuration(sg.metric_value))} ${esc(stretchMetric().label.toLowerCase())}</p>` : ""}`;

// Exact seconds on hover/focus/tap for every .dur on the page.
export function bindDurationTips() {
  let pinned = null;
  const show = (el) => {
    const r = el.getBoundingClientRect();
    showTip(`<p class="tip-m mono">${esc(el.dataset.exact || el.title)} exactly</p>`, { x: r.left, y: r.bottom - 6 });
  };
  document.addEventListener("pointerover", (e) => { const d = e.target.closest && e.target.closest(".dur"); if (d && e.pointerType === "mouse") show(d); });
  document.addEventListener("pointerout", (e) => { const d = e.target.closest && e.target.closest(".dur"); if (d && e.pointerType === "mouse" && d !== pinned) hideTip(); });
  document.addEventListener("focusin", (e) => { const d = e.target.closest && e.target.closest(".dur"); if (d) show(d); });
  document.addEventListener("focusout", (e) => { if (e.target.closest && e.target.closest(".dur")) hideTip(); });
  document.addEventListener("click", (e) => {
    const d = e.target.closest && e.target.closest(".dur");
    // Inside a list row the row's own action wins (the drawer shows the same durations to tap).
    if (d && !d.closest("button")) { if (pinned === d) { pinned = null; hideTip(); } else { pinned = d; show(d); } return; }
    if (pinned) { pinned = null; hideTip(); }
  });
}
