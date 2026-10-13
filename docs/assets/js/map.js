// MapLibre map: "Boston, 1775" period basemap (OpenFreeMap, no key), subway lines, station dots, live trains.
// Data colours = official line colours; every emphasis (hotspots, selection, focus) is drawn in ink.
/* global maplibregl */
import { CONFIG, LINES, lineOfRoute, HOT, fallbackLineColor, COMMUTER_RAIL, isCommuterRail, normHex } from "./config.js";
// "Red Line", "Green Line B", "Mattapan Line" from the route id (never from colour).
const lineLabelText = (routeId, lineId) => {
  const r = String(routeId || lineId || "");
  const g = r.match(/^Green-([A-E])$/);
  if (g) return `Green Line ${g[1]}`;
  if (["Red", "Orange", "Blue", "Green", "Mattapan"].includes(r)) return `${r} Line`;
  return "";
};
import { basemapStyle, MAP_FONT, MAP_FONT_ITALIC, PAPER, INK } from "./basemap.js";

const MBTA_ATTR = 'Transit data <a href="https://www.mbta.com/developers" target="_blank" rel="noopener">MBTA</a>';
const ACCENT = HOT; // hotspot accent = ink (config HOT); never a hue
const reduceMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Flat 2D train silhouette, nose up (bearing 0 = north): long rounded body, windshield, wheel dots.
// A dark outline separates neighbours; used from street zoom up.
function canvasFor(w, h, pad) {
  const pr = 2;
  const c = document.createElement("canvas");
  c.width = (w + pad * 2) * pr;
  c.height = (h + pad * 2) * pr;
  const g = c.getContext("2d");
  g.scale(pr, pr);
  g.translate(pad, pad);
  return { c, g };
}
const imageOf = ({ c, g }) => ({ width: c.width, height: c.height, data: g.getImageData(0, 0, c.width, c.height).data });

function trainGlyph(color, { light = false } = {}) {
  const w = 20, h = light ? 40 : 52, pad = 3;
  const cv = canvasFor(w, h, pad);
  const g = cv.g;
  const body = () => { g.beginPath(); g.roundRect(2.5, 0.5, w - 5, h - 1, (w - 5) / 2); };
  g.fillStyle = "rgba(43,33,24,0.7)";
  const wheelsY = light ? [10, 30] : [10, 22, 34, 44];
  for (const y of wheelsY) for (const x of [0.6, w - 0.6]) { g.beginPath(); g.arc(x, y, 1.4, 0, Math.PI * 2); g.fill(); }
  body();
  g.lineWidth = 2.6;
  g.strokeStyle = "rgba(248,242,228,0.9)"; // parchment casing
  g.stroke();
  g.fillStyle = color;
  g.fill();
  g.lineWidth = 1.1;
  g.strokeStyle = "rgba(43,33,24,0.9)";    // thin ink outline
  g.stroke();
  g.beginPath();
  g.roundRect(5.5, 4, w - 11, 6, 2.5);
  g.fillStyle = "rgba(43,33,24,0.55)";
  g.fill();
  return imageOf(cv);
}

// City-zoom marker: a small flat rounded rect with a dark outline, nose slightly brighter.
function trainDot(color) {
  const w = 8, h = 18, pad = 2;
  const cv = canvasFor(w, h, pad);
  const g = cv.g;
  g.beginPath();
  g.roundRect(0.5, 0.5, w - 1, h - 1, (w - 1) / 2);
  g.lineWidth = 2.2;
  g.strokeStyle = "rgba(248,242,228,0.9)";
  g.stroke();
  g.fillStyle = color;
  g.fill();
  g.lineWidth = 1;
  g.strokeStyle = "rgba(43,33,24,0.9)";
  g.stroke();
  g.beginPath();
  g.arc(w / 2, 4, 1.3, 0, Math.PI * 2);
  g.fillStyle = "rgba(248,242,228,0.9)";
  g.fill();
  return imageOf(cv);
}

const GLYPH_ZOOM = 13.5;
const SEG_OFFSET = ["interpolate", ["linear"], ["zoom"], 10, 1.1, 14, 3.4];
// Non-hotspot stretches: their line colour, thin and quiet (a little stronger the more they rank).
const SEG_BASE_OPACITY = ["case", ["has", "t"], ["interpolate", ["linear"], ["get", "t"], 0, 0.45, 1, 0.72], 0.35];


export const HOT_RANK = 0.9;  // top 10% of stations by riders meeting long gaps
export const WARM_RANK = 0.75;

// Midpoint along a [lon, lat] polyline plus the screen-space right-hand normal there (north-up map).
function midpointOf(coords) {
  if (!coords || coords.length < 2) return null;
  const k = Math.cos((coords[0][1] * Math.PI) / 180);
  const seg = [];
  let total = 0;
  for (let i = 1; i < coords.length; i++) {
    const dx = (coords[i][0] - coords[i - 1][0]) * k, dy = coords[i][1] - coords[i - 1][1];
    const l = Math.hypot(dx, dy);
    seg.push(l);
    total += l;
  }
  let acc = 0;
  for (let i = 0; i < seg.length; i++) {
    if (acc + seg[i] >= total / 2 || i === seg.length - 1) {
      const f = seg[i] ? (total / 2 - acc) / seg[i] : 0;
      const a = coords[i], b = coords[i + 1];
      const at = [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f];
      // screen direction: x east, y south
      const sx = (b[0] - a[0]) * k, sy = -(b[1] - a[1]);
      const L = Math.hypot(sx, sy) || 1;
      return { at, nx: -sy / L, ny: sx / L };
    }
    acc += seg[i];
  }
  return null;
}

const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const lerpAngle = (a, b, t) => {
  const d = ((((b - a) % 360) + 540) % 360) - 180;
  return (a + d * t + 360) % 360;
};

export class BoardMap {
  constructor(container, { onTrainHover, onTrainClick, onStationHover, onStationClick, onSegmentHover, onSegmentClick, onBackgroundClick, onSiteHover, onSiteClick }) {
    this.cb = { onTrainHover, onTrainClick, onStationHover, onStationClick, onSegmentHover, onSegmentClick, onBackgroundClick, onSiteHover, onSiteClick };
    this.segments = new Map(); // segment_id -> { coords, ... }
    this.trains = new Map(); // id -> { from, to, cur, data }
    this.anim = null;
    this.selectedLines = new Set(LINES.map((l) => l.line_id));
    this.crView = false;      // "Subway + Commuter Rail" view; opens on the subway view
    this.crColor = null;      // set in setNetwork (data colour or the official fallback)
    this.map = new maplibregl.Map({
      container,
      center: CONFIG.CENTER,
      zoom: CONFIG.ZOOM,
      // Phones show the network in a short strip above the cards, so they may zoom out a little more.
      minZoom: (this.baseMinZoom = window.innerWidth <= 860 ? 8 : 9),
      maxZoom: 17,
      attributionControl: false,
      dragRotate: false,
      pitchWithRotate: false,
      style: basemapStyle(),
    });
    this.map.addControl(new maplibregl.AttributionControl({ compact: true, customAttribution: MBTA_ATTR }), "bottom-right");
    this.map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "bottom-right");
    this.map.touchZoomRotate.disableRotation();
    // Scroll page: the map must never trap page scrolling. Touch: two-finger gestures
    // (cooperative); mouse: wheel zoom only after the map is clicked or focused.
    if (document.body.classList.contains("layout-scroll")) {
      const hint = document.getElementById("map-hint");
      if (window.matchMedia("(pointer: coarse)").matches) {
        this.map.cooperativeGestures.enable();
        if (hint) hint.textContent = "Two fingers to move the map";
      } else {
        this.map.scrollZoom.disable();
        const frame = container.closest(".map-frame") || container;
        const on = () => { this.map.scrollZoom.enable(); frame.classList.add("zoom-on"); };
        const off = () => { this.map.scrollZoom.disable(); frame.classList.remove("zoom-on"); };
        this.map.on("click", on);
        container.addEventListener("focusin", on);
        frame.addEventListener("mouseleave", off);
      }
    }
    this.loaded = new Promise((res) => this.map.on("load", res));
    this.userMoved = false;
    this.map.on("dragstart", () => { this.userMoved = true; });
    this.map.on("zoomstart", (e) => { if (e.originalEvent) this.userMoved = true; });
    // In the wide Commuter Rail view the ten rank badges would pile up over central Boston;
    // hide them when zoomed out that far (the hatched ink stretches stay visible).
    this.map.on("zoom", () => this.map.getContainer().classList.toggle("map-far", this.map.getZoom() < 8.3));
    // Start the attribution collapsed to its info button; it expands on tap.
    this.loaded.then(() => {
      const el = container.querySelector(".maplibregl-ctrl-attrib");
      if (el) el.classList.remove("maplibregl-compact-show");
    });
  }

  async setNetwork(net) {
    await this.loaded;
    const m = this.map;
    this.net = net;
    const lineColor = (l) => {
      const r = [...net.routes.values()].find((x) => lineOfRoute(x.id) && lineOfRoute(x.id).line_id === l.line_id);
      return (r && r.color) || fallbackLineColor(l.line_id);
    };
    // Exact published colours (routes.parquet route_color_hex); no muting, no overrides.
    this.lineColors = Object.fromEntries(LINES.map((l) => [l.line_id, lineColor(l)]));

    // Commuter Rail glyphs: routes.parquet colour for any CR-* route if present, else the API colour
    // seen in the live response (setTrains), else the official purple.
    const crRoute = [...net.routes.values()].find((r) => isCommuterRail(r.id) && normHex(r.color));
    this.crColorFromData = crRoute ? normHex(crRoute.color) : null;
    this.crColor = this.crColorFromData || COMMUTER_RAIL.FALLBACK_COLOR;
    this.lineColors[COMMUTER_RAIL.LINE_ID] = this.crColor; // tooltips only (chips iterate LINES)
    m.addImage(`train-${COMMUTER_RAIL.LINE_ID}`, trainGlyph(this.crColor), { pixelRatio: 2 });
    m.addImage(`dot-${COMMUTER_RAIL.LINE_ID}`, trainDot(this.crColor), { pixelRatio: 2 });
    for (const l of LINES) {
      const light = l.line_id === "Green" || l.line_id === "Mattapan";
      m.addImage(`train-${l.line_id}`, trainGlyph(this.lineColors[l.line_id], { light }), { pixelRatio: 2 });
      m.addImage(`dot-${l.line_id}`, trainDot(this.lineColors[l.line_id]), { pixelRatio: 2 });
    }

    const lines = net.lineFeatures.map((f) => ({
      ...f,
      properties: { ...f.properties, muted: this.lineColors[f.properties.line_id] || f.properties.color, label: lineLabelText(f.properties.route_id, f.properties.line_id) },
    }));
    m.addSource("lines", { type: "geojson", data: { type: "FeatureCollection", features: lines } });
    // Thin parchment casing under each line so it reads cleanly on the basemap.
    m.addLayer({
      id: "lines-casing",
      type: "line",
      source: "lines",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": PAPER, "line-width": ["interpolate", ["linear"], ["zoom"], 10, 2.6, 13, 4, 16, 6.6], "line-opacity": 0.95 },
    });
    m.addLayer({
      id: "lines",
      type: "line",
      source: "lines",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: {
        "line-color": ["get", "muted"],
        "line-width": ["interpolate", ["linear"], ["zoom"], 10, 1.05, 13, 2, 16, 4], // ~65% of the old width
        "line-opacity": 0.9,
      },
    });

    // Line names along the routes (colour-blind readers: never colour alone). EB Garamond italic, ink with
    // a parchment halo; from zoom 11 (Green branches from 12.5, where they separate). Collisions drop extras.
    m.addLayer({
      id: "lines-label",
      type: "symbol",
      source: "lines",
      minzoom: 11,
      filter: ["any", ["!", ["in", "Green-", ["get", "route_id"]]], [">=", ["zoom"], 12.5]],
      layout: {
        "symbol-placement": "line", "symbol-spacing": ["interpolate", ["linear"], ["zoom"], 11, 420, 15, 700],
        "text-field": ["get", "label"], "text-font": MAP_FONT_ITALIC,
        "text-size": ["interpolate", ["linear"], ["zoom"], 11, 11.5, 15, 14],
        "text-offset": [0, -0.85], "text-letter-spacing": 0.04, "text-keep-upright": true, "text-max-angle": 30, "text-padding": 6,
      },
      paint: { "text-color": INK, "text-halo-color": PAPER, "text-halo-width": 1.6, "text-halo-blur": 0.3 },
    });

    m.addSource("stations", { type: "geojson", data: this.stationGeo() });
    // hot = percentile rank (0..1) of gate entries in long gaps. Neutral greys only (bright for the top decile)
    // (hotspots), a mid grey for the next 15%, dark grey otherwise. nogate = station listed in
    // dbt coverage.stations_without_gated_entries: drawn hollow ("No gate data").
    // Track stretches (dbt segments): drawn by setSegments(); empty until then.
    m.addSource("segments", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
    // Stretches. Non-hotspots: line colour, thin, low opacity. Top 10 (hotspots): hatched ink casing,
    // hatched ink casing + double ink rule, and a numbered seal (HTML marker) at the
    // midpoint. Each direction is offset to its right-hand side so both directions stay visible.
    m.addLayer({
      id: "segments",
      type: "line",
      source: "segments",
      filter: ["!", ["get", "top"]],
      layout: { "line-cap": "butt", "line-join": "round", "line-sort-key": ["case", ["has", "t"], 1, 0] },
      paint: {
        "line-color": ["get", "muted"],
        "line-opacity": SEG_BASE_OPACITY,
        "line-width": ["interpolate", ["linear"], ["zoom"], 10, 0.8, 14, 1.8],
        "line-offset": SEG_OFFSET,
      },
    });
    m.addLayer({
      id: "segments-top-halo",
      type: "line",
      source: "segments",
      filter: ["get", "top"],
      layout: { "line-cap": "butt", "line-join": "round" },
      paint: {
        // Hatched ink casing: a wide dashed line reads as short cross-strokes along the stretch.
        "line-color": ACCENT,
        "line-opacity": 0.55,
        "line-width": ["interpolate", ["linear"], ["zoom"], 10, 7, 14, 13],
        "line-dasharray": [0.14, 0.26],
        "line-offset": SEG_OFFSET,
      },
    });
    m.addLayer({
      id: "segments-top",
      type: "line",
      source: "segments",
      filter: ["get", "top"],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: {
        // Double ink rule either side of the stretch (parchment between, line colour on top).
        "line-color": ACCENT,
        "line-opacity": 0.85,
        "line-width": ["interpolate", ["linear"], ["zoom"], 10, 0.8, 14, 1.2],
        "line-gap-width": ["interpolate", ["linear"], ["zoom"], 10, 3.4, 14, 6.5],
        "line-offset": SEG_OFFSET,
      },
    });
    m.addLayer({
      id: "segments-top-core",
      type: "line",
      source: "segments",
      filter: ["get", "top"],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: {
        "line-color": ["get", "muted"], // the stretch keeps its official line colour inside the ink rules
        "line-width": ["interpolate", ["linear"], ["zoom"], 10, 2.2, 14, 4.4],
        "line-offset": SEG_OFFSET,
      },
    });
    m.addLayer({
      id: "segment-selected",
      type: "line",
      source: "segments",
      filter: ["==", ["get", "id"], ""],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": INK, "line-width": ["interpolate", ["linear"], ["zoom"], 10, 2.2, 14, 3.4], "line-gap-width": ["interpolate", ["linear"], ["zoom"], 10, 4, 14, 8], "line-offset": ["interpolate", ["linear"], ["zoom"], 10, 1.1, 14, 3.4] }, // selected = heavier ink
    });
    // Insight-card focus on stretches: ink hairline outline.
    m.addLayer({
      id: "segment-focus",
      type: "line",
      source: "segments",
      filter: ["in", ["get", "id"], ["literal", []]],
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": INK, "line-width": 1.3, "line-gap-width": ["interpolate", ["linear"], ["zoom"], 10, 6, 14, 11], "line-offset": SEG_OFFSET },
    });
    m.addLayer({
      id: "segment-hit",
      type: "line",
      source: "segments",
      paint: { "line-color": "#000", "line-opacity": 0, "line-width": 14, "line-offset": ["interpolate", ["linear"], ["zoom"], 10, 1.1, 14, 3.4] },
    });
    m.addLayer({
      id: "stations",
      type: "circle",
      source: "stations",
      paint: {
        // Station dots: parchment fill, ink ring. Shading (riders meeting long gaps) is a single-hue
        // parchment -> sepia ink ramp: top decile ink-filled, next 15% sepia, the rest parchment.
        "circle-radius": [
          "interpolate", ["linear"], ["zoom"],
          10, ["case", [">=", ["coalesce", ["get", "hot"], -1], HOT_RANK], 3, 2.1],
          14, ["case", [">=", ["coalesce", ["get", "hot"], -1], HOT_RANK], 5.6, 4],
        ],
        "circle-color": [
          "case",
          ["has", "nogate"], PAPER,
          ["has", "hot"], ["step", ["get", "hot"], "#F8F2E4", WARM_RANK, "#A8916F", HOT_RANK, "#3B2E22"],
          ["has", "shaded"], "#F8F2E4",
          "#F8F2E4",
        ],
        "circle-stroke-color": INK,
        "circle-stroke-opacity": ["case", ["has", "nogate"], 0.4, 0.85], // no gate data: faint ring
        "circle-stroke-width": ["interpolate", ["linear"], ["zoom"], 10, 0.8, 14, 1.2],
      },
    });
    m.addLayer({
      id: "station-selected",
      type: "circle",
      source: "stations",
      filter: ["==", ["get", "id"], ""],
      paint: { "circle-radius": 10, "circle-color": "rgba(0,0,0,0)", "circle-stroke-color": INK, "circle-stroke-width": 2 },
    });
    m.addLayer({
      id: "station-focus",
      type: "circle",
      source: "stations",
      filter: ["in", ["get", "id"], ["literal", []]],
      paint: { "circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 6, 14, 10], "circle-color": "rgba(0,0,0,0)", "circle-stroke-color": INK, "circle-stroke-width": 1.2 },
    });
    // Invisible hit area, larger than the dot.
    m.addLayer({
      id: "station-hit",
      type: "circle",
      source: "stations",
      paint: { "circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 10, 14, 14], "circle-color": "#000", "circle-opacity": 0 },
    });

    m.addSource("trains", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
    m.addLayer({
      id: "train-selected",
      type: "circle",
      source: "trains",
      filter: ["==", ["get", "id"], ""],
      paint: { "circle-radius": 15, "circle-color": "rgba(43,33,24,0.06)", "circle-stroke-color": INK, "circle-stroke-width": 1.6 },
    });
    m.addLayer({
      id: "trains",
      type: "symbol",
      source: "trains",
      layout: {
        "icon-image": ["step", ["zoom"], ["concat", "dot-", ["get", "line_id"]], GLYPH_ZOOM, ["concat", "train-", ["get", "line_id"]]],
        "icon-rotate": ["get", "bearing"],
        "icon-rotation-alignment": "map",
        "icon-allow-overlap": true,
        "icon-ignore-placement": true,
        "icon-size": ["interpolate", ["linear"], ["zoom"], 10, 0.62, GLYPH_ZOOM - 0.01, 0.95, GLYPH_ZOOM, 0.6, 16, 1],
      },
    });
    // Invisible hit area for trains: bigger target, same glyph size.
    m.addLayer({
      id: "train-hit",
      type: "circle",
      source: "trains",
      paint: { "circle-radius": ["interpolate", ["linear"], ["zoom"], 10, 9, 15, 16], "circle-color": "#000", "circle-opacity": 0 },
    });

    this.bindPointer();
    this.applyLineFilter();
    this.applyTrainFilter();
    this.fitNetwork();
    // Panels settle after fonts and data load; refit once unless the reader already moved the map.
    setTimeout(() => this.refit(), 600);
    window.addEventListener("resize", () => { clearTimeout(this.rt); this.rt = setTimeout(() => this.refit(), 200); });
  }

  // Fit the network into the map area left visible by the frost panels.
  // "+ Commuter Rail" view: the subway plus the CR extent (dbt CR stops once wired, else the
  // configured terminal bounds) plus any live CR train outside it.
  fitNetwork({ animate = false } = {}) {
    if (!this.net || !this.net.stations.size) return;
    const b = new maplibregl.LngLatBounds();
    for (const s of this.net.stations.values()) b.extend([s.lon, s.lat]);
    if (this.crView) {
      if (this.crStations && this.crStations.length) for (const s of this.crStations) b.extend([s.lon, s.lat]);
      else for (const p of COMMUTER_RAIL.BOUNDS) b.extend(p);
      for (const t of this.trains.values()) if (t.data.lineId === COMMUTER_RAIL.LINE_ID) b.extend([t.to.lon, t.to.lat]);
    }
    this.map.fitBounds(b, { padding: this.visiblePadding(), duration: animate && !reduceMotion() ? 600 : 0, maxZoom: 13 });
  }

  setCommuterRailView(on) {
    this.crView = !!on;
    // The CR extent needs a wider view than the subway's minimum zoom allows.
    this.map.setMinZoom(this.crView ? 7 : this.baseMinZoom);
    this.applyTrainFilter();
    this.userMoved = false;
    this.fitNetwork({ animate: true });
  }

  applyTrainFilter() {
    if (!this.map.getLayer("trains")) return;
    const f = this.crView ? null : ["!=", ["get", "line_id"], COMMUTER_RAIL.LINE_ID];
    for (const id of ["trains", "train-hit"]) this.map.setFilter(id, f);
    if (this.map.getLayer("cr-lines")) this.map.setLayoutProperty("cr-lines", "visibility", this.crView ? "visible" : "none");
  }

  // HOOK (not called yet): the dbt build's CR track shapes / stops. lineFeatures: GeoJSON LineStrings with
  // properties.route_id (CR-*); stations: [{ id, name, lon, lat }]. Drawn only in the CR view,
  // beneath the subway, in the CR colour.
  setCommuterRailNetwork(lineFeatures = [], stations = []) {
    this.crStations = stations;
    const data = { type: "FeatureCollection", features: lineFeatures };
    if (this.map.getSource("cr-lines")) this.map.getSource("cr-lines").setData(data);
    else {
      this.map.addSource("cr-lines", { type: "geojson", data });
      this.map.addLayer({
        id: "cr-lines", type: "line", source: "cr-lines",
        layout: { "line-cap": "round", "line-join": "round", visibility: this.crView ? "visible" : "none" },
        paint: { "line-color": this.crColor || COMMUTER_RAIL.FALLBACK_COLOR, "line-width": 1.1, "line-opacity": 0.7 },
      }, "lines");
    }
  }

  visiblePadding() {
    const rect = (sel) => {
      const el = document.querySelector(sel);
      // panels are position:fixed (offsetParent is always null), so check display instead
      return el && getComputedStyle(el).display !== "none" ? el.getBoundingClientRect() : null;
    };
    if (document.body.classList.contains("layout-scroll")) {
      // Scroll page: the map sits in its own plate; keep clear of the in-plate controls and of the
      // details panel where it overlaps the plate's right edge.
      const c = this.map.getContainer().getBoundingClientRect();
      const pad = { top: 30, bottom: 30, left: 30, right: 30 };
      const d = rect(".drawer"), vt = rect(".view-toggle");
      if (d && document.body.classList.contains("drawer-open") && window.innerWidth > 860 && d.left < c.right && d.left > c.left) pad.right = c.right - d.left + 18;
      if (vt && vt.top < c.bottom) pad.bottom = Math.max(pad.bottom, c.bottom - vt.top + 12);
      if (c.width - pad.left - pad.right < 160) pad.right = pad.left = 20;
      if (c.height - pad.top - pad.bottom < 140) pad.top = pad.bottom = 16;
      return pad;
    }
    const W = window.innerWidth, H = window.innerHeight;
    const top = rect(".topbar"), rail = rect(".rail"), dock = rect(".dock"), drawer = rect(".drawer"), charts = rect(".charts");
    const phone = W <= 860;
    const pad = { top: 24, bottom: 24, left: 24, right: 24 };
    const m = 14; // breathing room inside the visible gap
    if (top) pad.top = top.bottom + m;
    if (dock) pad.bottom = H - dock.top + m;
    if (rail) {
      if (!phone) pad.left = rail.right + m;
      // phones: the card strip sits under the map (more room above it than below)
      else if (rail.top - (top ? top.bottom : 0) > H - rail.bottom) {
        pad.bottom = Math.max(pad.bottom, H - rail.top + m);
        const vt = rect(".view-toggle");
        if (vt && vt.height) pad.top = Math.max(pad.top, vt.bottom + 6);
      } else pad.top = rail.bottom + m;
    }
    if (drawer && !phone && drawer.left > W / 2) pad.right = W - drawer.left + m;
    if (charts && !phone && charts.left > W / 2) pad.right = Math.max(pad.right, W - charts.left + m);
    if (charts && phone && charts.top > H / 4) pad.bottom = Math.max(pad.bottom, H - charts.top + m);
    // keep at least a 120 px box for the network
    if (W - pad.left - pad.right < 120) pad.left = pad.right = 16;
    if (H - pad.top - pad.bottom < 120) { pad.top = Math.min(pad.top, H / 3); pad.bottom = Math.min(pad.bottom, H / 3); }
    if (phone && drawer && drawer.top > H / 3) pad.bottom = Math.max(pad.bottom, H - drawer.top + m);
    if (H - pad.top - pad.bottom < 80) { pad.top = Math.min(pad.top, H * 0.3); pad.bottom = Math.min(pad.bottom, H * 0.45); }
    return pad;
  }

  refit() {
    if (!this.userMoved) this.fitNetwork();
  }

  stationGeo(shade = null, noGate = this.noGate) {
    const features = [];
    for (const s of (this.net ? this.net.stations.values() : [])) {
      const lines = new Set([...s.routeIds].map((r) => (lineOfRoute(r) || {}).line_id).filter(Boolean));
      const props = { id: s.id, name: s.name, lines: `|${[...lines].join("|")}|` };
      if (noGate && noGate.has(s.id)) props.nogate = 1;
      else if (shade && shade.has(s.id)) props.hot = shade.get(s.id);
      else if (shade) props.shaded = 1;
      features.push({ type: "Feature", properties: props, geometry: { type: "Point", coordinates: [s.lon, s.lat] } });
    }
    return { type: "FeatureCollection", features };
  }

  // shade: Map(station_id -> 0..1) or null to clear (no dbt data yet)
  // noGate: Set(station_id) from dbt coverage; kept across shading updates.
  setNoGate(noGate) {
    this.noGate = noGate && noGate.size ? noGate : null;
  }

  setStationShading(shade) {
    this.shade = shade;
    if (!this.map.getSource("stations")) return;
    this.map.getSource("stations").setData(this.stationGeo(shade));
  }

  setSelectedLines(set) {
    this.selectedLines = new Set(set);
    this.applyLineFilter();
  }

  applyLineFilter() {
    const m = this.map;
    if (!m.getLayer("lines")) return;
    const sel = [...this.selectedLines];
    const lineOn = ["in", ["get", "line_id"], ["literal", sel]];
    const stationOn = ["any", ...sel.map((id) => ["in", `|${id}|`, ["get", "lines"]]), false];
    m.setPaintProperty("lines", "line-opacity", ["case", lineOn, this.hasSegments ? 0.3 : 0.9, this.hasSegments ? 0.07 : 0.16]);
    m.setPaintProperty("stations", "circle-opacity", ["case", stationOn, 1, 0.18]);
    m.setPaintProperty("stations", "circle-stroke-opacity", ["case", stationOn, 1, 0.18]);
    m.setPaintProperty("trains", "icon-opacity", ["case", ["any", lineOn, ["==", ["get", "line_id"], COMMUTER_RAIL.LINE_ID]], 1, 0.12]);
    if (m.getLayer("segments")) {
      const segOn = ["in", ["get", "line_id"], ["literal", sel]];
      m.setPaintProperty("segments", "line-opacity", ["case", segOn, SEG_BASE_OPACITY, 0.05]);
      // Hotspots on a de-selected line fade out entirely, badge included.
      m.setPaintProperty("segments-top-halo", "line-opacity", ["case", segOn, 0.55, 0]);
      m.setPaintProperty("segments-top", "line-opacity", ["case", segOn, 1, 0.1]);
      m.setPaintProperty("segments-top-core", "line-opacity", ["case", segOn, 1, 0]);
    }
    for (const [id, mk] of this.badges || []) {
      const sg = this.segments.get(id);
      mk.getElement().hidden = !!sg && !this.selectedLines.has(sg.line_id);
    }
    this.applyFocusPaint();
  }

  // ---------------------------------------------------------------- insight-card focus
  // focus: { lines: [line_id], segments: [segment_id], stations: [station_id] } or null.
  // Highlights what the card is about, dims the rest and flies there; null restores the board.
  setFocus(focus) {
    const has = (k) => focus && Array.isArray(focus[k]) && focus[k].length;
    this.focusSel = has("lines") || has("segments") || has("stations")
      ? { lines: focus.lines || [], segments: focus.segments || [], stations: focus.stations || [] } : null;
    this.applyLineFilter();
    if (this.focusSel) this.flyToFocus();
    else { this.userMoved = false; this.fitNetwork({ animate: true }); }
  }

  applyFocusPaint() {
    const m = this.map;
    if (!m.getLayer("segment-focus")) return;
    const F = this.focusSel;
    m.setFilter("segment-focus", ["in", ["get", "id"], ["literal", F ? F.segments : []]]);
    m.setFilter("station-focus", ["in", ["get", "id"], ["literal", F ? F.stations : []]]);
    if (!F) return;
    const lit = (a) => ["literal", a];
    const ends = F.segments.flatMap((id) => { const sg = this.segments.get(id); return sg ? [sg.from_station_id, sg.to_station_id] : []; });
    const lineOn = ["in", ["get", "line_id"], lit(F.lines)];
    const segOn = F.segments.length ? ["in", ["get", "id"], lit(F.segments)] : lineOn;
    const stOn = ["any", ["in", ["get", "id"], lit([...F.stations, ...ends])], ...F.lines.map((id) => ["in", `|${id}|`, ["get", "lines"]])];
    m.setPaintProperty("lines", "line-opacity", ["case", lineOn, this.hasSegments ? 0.4 : 0.9, F.segments.length ? 0.1 : 0.05]);
    m.setPaintProperty("stations", "circle-opacity", ["case", stOn, 1, 0.12]);
    m.setPaintProperty("stations", "circle-stroke-opacity", ["case", stOn, 1, 0.12]);
    m.setPaintProperty("trains", "icon-opacity", F.lines.length ? ["case", lineOn, 1, 0.1] : 0.3);
    if (m.getLayer("segments")) {
      m.setPaintProperty("segments", "line-opacity", ["case", segOn, 0.85, 0.03]);
      m.setPaintProperty("segments-top-halo", "line-opacity", ["case", segOn, 0.55, 0]);
      m.setPaintProperty("segments-top", "line-opacity", ["case", segOn, 1, 0.07]);
      m.setPaintProperty("segments-top-core", "line-opacity", ["case", segOn, 1, 0]);
    }
    for (const [id, mk] of this.badges || []) {
      const sg = this.segments.get(id);
      const on = F.segments.length ? F.segments.includes(id) : F.lines.length ? !!sg && F.lines.includes(sg.line_id) : false;
      mk.getElement().hidden = !on;
    }
  }

  flyToFocus() {
    const F = this.focusSel;
    if (!F) return;
    const b = new maplibregl.LngLatBounds();
    let n = 0;
    const add = (p) => { if (Array.isArray(p) && Number.isFinite(p[0]) && Number.isFinite(p[1])) { b.extend(p); n += 1; } };
    for (const id of F.segments) { const sg = this.segments.get(id); if (sg) sg.coords.forEach(add); }
    if (this.net) {
      for (const f of this.net.lineFeatures) {
        if (!F.lines.includes(f.properties && f.properties.line_id)) continue;
        const g = f.geometry || {};
        (g.type === "MultiLineString" ? g.coordinates.flat() : g.coordinates || []).forEach(add);
      }
      for (const id of F.stations) { const s = this.net.stations.get(id); if (s) add([s.lon, s.lat]); }
    }
    if (!n) return;
    const maxZoom = F.segments.length && !F.lines.length ? 13.6 : 13; // keep the neighbourhood in view
    this.map.fitBounds(b, { padding: this.visiblePadding(), maxZoom, duration: reduceMotion() ? 0 : 800 });
    this.userMoved = true;
  }

  select({ trainId = "", stationId = "", segmentId = "" } = {}) {
    if (!this.map.getLayer("trains")) return;
    this.map.setFilter("train-selected", ["==", ["get", "id"], trainId]);
    this.map.setFilter("station-selected", ["==", ["get", "id"], stationId]);
    this.map.setFilter("segment-selected", ["==", ["get", "id"], segmentId]);
  }

  // rows: [{ segment_id, line_id, geometry: [[lon, lat]], metric_rank, metric_top }] (ranking metric
  // from config STRETCH_METRIC). Rank shading: t = 1 just below the top 10, 0 for the last ranked.
  async setSegments(rows) {
    await this.loaded;
    const src = this.map.getSource("segments");
    if (!src) return;
    this.segments = new Map();
    const ranked = (rows || []).filter((r) => Number.isFinite(r.metric_rank));
    const maxRank = ranked.length ? Math.max(...ranked.map((r) => r.metric_rank)) : 0;
    const features = [];
    for (const r of rows || []) {
      const coords = Array.isArray(r.geometry) ? r.geometry.filter((p) => Array.isArray(p) && p.length >= 2) : [];
      if (coords.length < 2) continue;
      this.segments.set(r.segment_id, { ...r, coords });
      const props = { id: r.segment_id, line_id: r.line_id, top: !!r.metric_top, muted: this.lineColors[r.line_id] || fallbackLineColor(r.line_id) || "#666" };
      if (Number.isFinite(r.metric_rank) && !r.metric_top && maxRank > 10) props.t = 1 - (r.metric_rank - 11) / Math.max(1, maxRank - 11);
      features.push({ type: "Feature", properties: props, geometry: { type: "LineString", coordinates: coords } });
    }
    src.setData({ type: "FeatureCollection", features });
    // With stretches drawn, the plain line layer only peeks through as identity.
    this.map.setPaintProperty("lines", "line-opacity", features.length ? 0.3 : 0.9);
    this.hasSegments = features.length > 0;
    this.setBadges();
    this.applyLineFilter();
  }

  // ---------------------------------------------------------------- Freedom Trail (the dbt build's table)
  // sites: [{ order, name, lon, lat, stopId, ... }] sorted by order. Numbered ink marks, italic names
  // at street zoom, and a faint dotted ink path in site order (not the walking route).
  async setFreedomTrail(sites, visible, { pathLabel = "" } = {}) {
    await this.loaded;
    const m = this.map;
    const pts = (sites || []).filter((s) => Number.isFinite(s.lon) && Number.isFinite(s.lat));
    this.ftSites = new Map(pts.map((s) => [String(s.order), s]));
    const data = { type: "FeatureCollection", features: pts.map((s) => ({ type: "Feature", properties: { k: String(s.order), n: String(s.order), name: s.name || "" }, geometry: { type: "Point", coordinates: [s.lon, s.lat] } })) };
    const path = { type: "FeatureCollection", features: pts.length > 1 ? [{ type: "Feature", properties: { label: pathLabel }, geometry: { type: "LineString", coordinates: pts.map((s) => [s.lon, s.lat]) } }] : [] };
    if (!m.getSource("ft")) {
      m.addSource("ft", { type: "geojson", data });
      m.addSource("ft-path", { type: "geojson", data: path });
      const before = "trains";
      m.addLayer({ id: "ft-path", type: "line", source: "ft-path", layout: { "line-cap": "round", "line-join": "round" },
        paint: { "line-color": INK, "line-opacity": 0.45, "line-width": 1.2, "line-dasharray": [0.4, 2.2] } }, before);
      m.addLayer({ id: "ft-path-label", type: "symbol", source: "ft-path", minzoom: 14,
        layout: { "symbol-placement": "line", "symbol-spacing": 520, "text-field": ["get", "label"], "text-font": MAP_FONT_ITALIC, "text-size": 11.5, "text-offset": [0, -0.8] },
        paint: { "text-color": INK, "text-opacity": 0.75, "text-halo-color": PAPER, "text-halo-width": 1.2 } }, before);
      m.addLayer({ id: "ft-mark", type: "circle", source: "ft",
        paint: { "circle-radius": ["interpolate", ["linear"], ["zoom"], 11, 4.5, 15, 7.5], "circle-color": INK, "circle-stroke-color": PAPER, "circle-stroke-width": 1.2 } }, before);
      m.addLayer({ id: "ft-num", type: "symbol", source: "ft", minzoom: 12.5,
        layout: { "text-field": ["get", "n"], "text-font": MAP_FONT, "text-size": ["interpolate", ["linear"], ["zoom"], 12.5, 8.5, 15, 11], "text-allow-overlap": true, "text-ignore-placement": true },
        paint: { "text-color": PAPER } }, before);
      m.addLayer({ id: "ft-name", type: "symbol", source: "ft", minzoom: 14,
        layout: { "text-field": ["get", "name"], "text-font": MAP_FONT_ITALIC, "text-size": 12.5, "text-anchor": "left", "text-offset": [0.9, 0], "text-optional": true, "text-max-width": 9 },
        paint: { "text-color": INK, "text-halo-color": PAPER, "text-halo-width": 1.4 } }, before);
      m.on("mousemove", "ft-mark", (e) => { const f = e.features && e.features[0]; m.getCanvas().style.cursor = "pointer"; this.cb.onSiteHover && f && this.cb.onSiteHover(this.ftSites.get(f.properties.k), e.point); });
      m.on("mouseleave", "ft-mark", () => { m.getCanvas().style.cursor = ""; this.cb.onSiteHover && this.cb.onSiteHover(null); });
      m.on("click", "ft-mark", (e) => { const f = e.features && e.features[0]; if (f && this.cb.onSiteClick) { e.preventDefault(); this.cb.onSiteClick(this.ftSites.get(f.properties.k), e.point); } });
    } else {
      m.getSource("ft").setData(data);
      m.getSource("ft-path").setData(path);
    }
    for (const id of ["ft-path", "ft-path-label", "ft-mark", "ft-num", "ft-name"]) m.setLayoutProperty(id, "visibility", visible ? "visible" : "none");
  }

  // Highlight one station (a Freedom Trail site's nearest stop) without moving the map.
  markStation(stationId) {
    if (!this.map.getLayer("station-focus")) return;
    this.ftStation = stationId || null;
    this.map.setFilter("station-focus", ["in", ["get", "id"], ["literal", stationId ? [stationId, ...((this.focusSel && this.focusSel.stations) || [])] : ((this.focusSel && this.focusSel.stations) || [])]]);
  }

  // Rank seals for the top 10: HTML markers (ink roundels, parchment numerals) at each stretch's midpoint, nudged to
  // the stretch's right-hand side so the two directions of one stretch don't stack.
  setBadges() {
    for (const mk of (this.badges || new Map()).values()) mk.remove();
    this.badges = new Map();
    for (const sg of this.segments.values()) {
      if (!sg.metric_top || !Number.isFinite(sg.metric_rank)) continue;
      const mid = midpointOf(sg.coords);
      if (!mid) continue;
      const el = document.createElement("button");
      el.type = "button";
      el.className = "seg-badge";
      el.textContent = String(sg.metric_rank);
      el.setAttribute("aria-label", `Top ${sg.metric_rank}: ${sg.segment_name}`);
      el.addEventListener("click", (e) => { e.stopPropagation(); this.cb.onSegmentClick && this.cb.onSegmentClick(sg.segment_id); });
      el.addEventListener("mouseenter", () => {
        const r = el.getBoundingClientRect(), c = this.map.getCanvas().getBoundingClientRect();
        this.cb.onSegmentHover && this.cb.onSegmentHover(sg.segment_id, { x: r.left + r.width / 2 - c.left, y: r.top - c.top });
      });
      el.addEventListener("mouseleave", () => this.cb.onSegmentHover && this.cb.onSegmentHover(null));
      const off = [mid.nx * 13, mid.ny * 13];
      const mk = new maplibregl.Marker({ element: el, offset: off }).setLngLat(mid.at).addTo(this.map);
      this.badges.set(sg.segment_id, mk);
    }
  }

  // Bring a stretch or station into the visible map area (between the panels).
  focus({ segmentId, stationId } = {}) {
    const pad = this.visiblePadding();
    if (segmentId && this.segments.has(segmentId)) {
      const b = new maplibregl.LngLatBounds();
      for (const p of this.segments.get(segmentId).coords) b.extend(p);
      this.map.fitBounds(b, { padding: pad, maxZoom: 14.5, duration: reduceMotion() ? 0 : 700 });
      this.userMoved = true;
    } else if (stationId && this.net && this.net.stations.has(stationId)) {
      const s = this.net.stations.get(stationId);
      this.map.easeTo({ center: [s.lon, s.lat], zoom: Math.max(this.map.getZoom(), 13.5), padding: pad, duration: reduceMotion() ? 0 : 700 });
      this.userMoved = true;
    }
  }

  // Tween trains from their current on-screen position to the new fix.
  setTrains(vehicles) {
    const now = performance.now();
    const next = new Map();
    for (const v of vehicles) {
      const line = lineOfRoute(v.routeId);
      const cr = !line && (isCommuterRail(v.routeId) || v.routeType === COMMUTER_RAIL.ROUTE_TYPE);
      if (!line && !cr) continue;
      const prev = this.trains.get(v.id);
      const to = { lon: v.lon, lat: v.lat, bearing: v.bearing };
      const from = prev ? { ...prev.cur } : { ...to };
      next.set(v.id, { from, to, cur: { ...from }, data: { ...v, lineId: line ? line.line_id : COMMUTER_RAIL.LINE_ID } });
      // No CR colour in routes.parquet: take the route colour from the live response (still data).
      if (cr && !this.crColorFromData && v.routeColor && v.routeColor !== this.crColor && this.map.hasImage(`train-${COMMUTER_RAIL.LINE_ID}`)) {
        this.crColor = v.routeColor;
        this.lineColors[COMMUTER_RAIL.LINE_ID] = this.crColor;
        this.map.updateImage(`train-${COMMUTER_RAIL.LINE_ID}`, trainGlyph(this.crColor));
        this.map.updateImage(`dot-${COMMUTER_RAIL.LINE_ID}`, trainDot(this.crColor));
      }
    }
    this.trains = next;
    this.animStart = now;
    if (reduceMotion()) {
      for (const t of this.trains.values()) t.cur = { ...t.to };
      this.renderTrains();
      return;
    }
    if (!this.anim) this.anim = requestAnimationFrame((ts) => this.step(ts));
  }

  step(ts) {
    const t = Math.min(1, (ts - this.animStart) / CONFIG.TWEEN_MS);
    const k = ease(Math.max(0, t));
    for (const tr of this.trains.values()) {
      tr.cur = {
        lon: tr.from.lon + (tr.to.lon - tr.from.lon) * k,
        lat: tr.from.lat + (tr.to.lat - tr.from.lat) * k,
        bearing: lerpAngle(tr.from.bearing, tr.to.bearing, k),
      };
    }
    this.renderTrains();
    this.anim = t < 1 ? requestAnimationFrame((n) => this.step(n)) : null;
  }

  renderTrains() {
    const src = this.map.getSource("trains");
    if (!src) return;
    const features = [];
    for (const [id, tr] of this.trains) {
      features.push({
        type: "Feature",
        properties: { id, line_id: tr.data.lineId, bearing: tr.cur.bearing },
        geometry: { type: "Point", coordinates: [tr.cur.lon, tr.cur.lat] },
      });
    }
    src.setData({ type: "FeatureCollection", features });
  }

  train(id) {
    const t = this.trains.get(id);
    return t ? t.data : null;
  }

  trainScreenPoint(id) {
    const t = this.trains.get(id);
    return t ? this.map.project([t.cur.lon, t.cur.lat]) : null;
  }

  bindPointer() {
    const m = this.map;
    const canvas = m.getCanvas();
    // Whatever is actually nearest the pointer wins; stations get a small bias over passing trains.
    // Trains and stations win over a stretch under them (small bias); stretches use the distance
    // from the pointer to their drawn line.
    const segDist = (id, pt) => {
      const sg = this.segments.get(id);
      if (!sg) return Infinity;
      let best = Infinity;
      const P = sg.coords.map((c) => m.project(c));
      for (let i = 1; i < P.length; i += 1) {
        const a = P[i - 1], b = P[i];
        const dx = b.x - a.x, dy = b.y - a.y, L = dx * dx + dy * dy;
        const t = L ? Math.max(0, Math.min(1, ((pt.x - a.x) * dx + (pt.y - a.y) * dy) / L)) : 0;
        best = Math.min(best, Math.hypot(pt.x - (a.x + t * dx), pt.y - (a.y + t * dy)));
      }
      return best;
    };
    const pick = (e) => {
      const layers = ["station-hit", "train-hit"].concat(this.hasSegments ? ["segment-hit"] : []);
      const hits = m.queryRenderedFeatures(e.point, { layers });
      let best = null, bestD = Infinity;
      const seen = new Set();
      for (const f of hits) {
        let d;
        if (f.layer.id === "segment-hit") {
          if (seen.has(f.properties.id)) continue;
          seen.add(f.properties.id);
          d = segDist(f.properties.id, e.point) + 6;
        } else {
          const p = m.project(f.geometry.coordinates);
          d = Math.hypot(p.x - e.point.x, p.y - e.point.y) - (f.layer.id === "station-hit" ? 4 : 0);
        }
        if (d < bestD) { bestD = d; best = f; }
      }
      if (!best) return null;
      const kind = best.layer.id === "train-hit" ? "train" : best.layer.id === "segment-hit" ? "segment" : "station";
      return { kind, id: best.properties.id };
    };
    const clearHover = () => { this.cb.onTrainHover(null); this.cb.onStationHover(null); this.cb.onSegmentHover && this.cb.onSegmentHover(null); };
    const onSite = (e) => m.getLayer("ft-mark") && m.getLayoutProperty("ft-mark", "visibility") !== "none" && m.queryRenderedFeatures(e.point, { layers: ["ft-mark"] }).length > 0;
    m.on("mousemove", (e) => {
      if (onSite(e)) return; // Freedom Trail marks handle their own hover
      const f = pick(e);
      canvas.style.cursor = f ? "pointer" : "";
      if (!f) return clearHover();
      if (f.kind === "train") this.cb.onTrainHover(f.id, e.point);
      else if (f.kind === "station") this.cb.onStationHover(f.id, e.point);
      else if (this.cb.onSegmentHover) this.cb.onSegmentHover(f.id, e.point);
    });
    m.on("mouseout", clearHover);
    m.on("click", (e) => {
      if (onSite(e)) return;
      const f = pick(e);
      if (!f) this.cb.onBackgroundClick();
      else if (f.kind === "train") this.cb.onTrainClick(f.id, e.point);
      else if (f.kind === "station") this.cb.onStationClick(f.id);
      else if (this.cb.onSegmentClick) this.cb.onSegmentClick(f.id);
    });
  }
}
