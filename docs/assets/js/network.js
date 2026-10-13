// Subway lines and stations. Prefers the dbt `map` block in board_data.json (stations, stop order
// and GTFS track shapes); then the dbt map Parquet; one MBTA V3 request only when neither exists.
import { CONFIG, LINES, lineOfRoute, normHex } from "./config.js";
import { BOARD_KEYS } from "./queries.js";
import { mbta, indexIncluded } from "./api.js";

// Google encoded polyline, precision 5 -> [[lon, lat], ...]
export function decodePolyline(str) {
  const coords = [];
  let i = 0, lat = 0, lon = 0;
  while (i < str.length) {
    for (const axis of [0, 1]) {
      let shift = 0, result = 0, b;
      do {
        b = str.charCodeAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      const d = result & 1 ? ~(result >> 1) : result >> 1;
      if (axis === 0) lat += d; else lon += d;
    }
    coords.push([lon / 1e5, lat / 1e5]);
  }
  return coords;
}

// Fallback only when no colour column exists (published MBTA values in config LINES).
const fallbackColor = (routeId) => (lineOfRoute(routeId) || {}).fallbackColor || null;
const hex = normHex;

function emptyNetwork(source) {
  return { source, routes: new Map(), lineFeatures: [], stations: new Map(), platforms: new Map() };
}

function fromBoard(map) {
  const net = emptyNetwork("dbt");
  for (const s of map[BOARD_KEYS.mapStations] || []) {
    const routeIds = Array.isArray(s.route_ids) ? s.route_ids : String(s.route_ids || "").split(",").filter(Boolean);
    const lon = Number(s.lon ?? s.longitude), lat = Number(s.lat ?? s.latitude);
    if (!Number.isFinite(lon) || !Number.isFinite(lat)) continue;
    net.stations.set(s.station_id, { id: s.station_id, name: s.name ?? s.station_name, lon, lat, routeIds: new Set(routeIds) });
  }
  const allLines = map[BOARD_KEYS.mapLines] || [];
  // Destinations per route from every direction entry; draw one direction per branch.
  const dest = new Map();
  for (const line of allLines) {
    if (line.direction_destinations) { dest.set(line.route_id, line.direction_destinations); continue; }
    if (line.destination == null || line.direction_id == null) continue;
    const d = dest.get(line.route_id) || [null, null];
    if (!d[line.direction_id]) d[line.direction_id] = line.destination;
    dest.set(line.route_id, d);
  }
  const drawn = new Set();
  for (const line of allLines) {
    const routeId = line.route_id;
    const branch = line.branch_route_id || routeId;
    const color = hex(line.color || line.route_color_hex) || fallbackColor(routeId);
    if (!net.routes.has(routeId)) net.routes.set(routeId, { id: routeId, color, name: line.display_name || line.route_name || routeId, destinations: dest.get(routeId) || null });
    if (drawn.has(branch)) continue;
    drawn.add(branch);
    // Track geometry: dbt `shape` ([[lon, lat], ...] from GTFS shapes). Straight station-to-station
    // segments only if a branch has no shape.
    const shape = line[BOARD_KEYS.mapShape];
    const coords = Array.isArray(shape) && shape.length > 1
      ? shape
      : (line.stops || []).map((id) => net.stations.get(id)).filter(Boolean).map((s) => [s.lon, s.lat]);
    if (coords.length > 1) net.lineFeatures.push(lineFeature(routeId, color, coords));
  }
  return net;
}

function lineFeature(routeId, color, coords) {
  const line = lineOfRoute(routeId);
  return {
    type: "Feature",
    properties: { route_id: routeId, line_id: line ? line.line_id : routeId, color },
    geometry: { type: "LineString", coordinates: coords },
  };
}

async function fromApi() {
  const net = emptyNetwork("api");
  const doc = await mbta("/route_patterns", {
    "filter[route]": CONFIG.SUBWAY_ROUTES.join(","),
    "filter[canonical]": "true",
    include: "route,representative_trip.shape,representative_trip.stops",
    "fields[route_pattern]": "name,direction_id",
    "fields[route]": "long_name,color,text_color,direction_destinations",
    "fields[trip]": "headsign",
    "fields[shape]": "polyline",
    "fields[stop]": "name,latitude,longitude",
  });
  const inc = indexIncluded(doc);

  for (const item of doc.included || []) {
    if (item.type !== "route") continue;
    net.routes.set(item.id, {
      id: item.id,
      color: hex(item.attributes.color) || fallbackColor(item.id),
      name: item.attributes.long_name,
      destinations: item.attributes.direction_destinations || null,
    });
  }

  const sums = new Map(); // parent station -> running mean of platform coordinates
  const seenShapes = new Set();
  for (const rp of doc.data) {
    const routeId = rp.relationships.route.data.id;
    const color = (net.routes.get(routeId) || {}).color || fallbackColor(routeId);
    const tripRef = rp.relationships.representative_trip.data;
    const trip = tripRef && inc.get(`trip:${tripRef.id}`);
    if (!trip) continue;
    const shapeRef = trip.relationships.shape && trip.relationships.shape.data;
    const shape = shapeRef && inc.get(`shape:${shapeRef.id}`);
    if (shape && !seenShapes.has(shape.id)) {
      seenShapes.add(shape.id);
      net.lineFeatures.push(lineFeature(routeId, color, decodePolyline(shape.attributes.polyline)));
    }
    for (const ref of (trip.relationships.stops && trip.relationships.stops.data) || []) {
      const stop = inc.get(`stop:${ref.id}`);
      if (!stop) continue;
      const parent = stop.relationships.parent_station && stop.relationships.parent_station.data;
      const sid = parent ? parent.id : stop.id;
      net.platforms.set(stop.id, sid);
      let st = net.stations.get(sid);
      if (!st) {
        st = { id: sid, name: stop.attributes.name, lon: 0, lat: 0, routeIds: new Set() };
        net.stations.set(sid, st);
        sums.set(sid, { n: 0, lon: 0, lat: 0, seen: new Set() });
      }
      st.routeIds.add(routeId);
      const acc = sums.get(sid);
      if (!acc.seen.has(stop.id)) {
        acc.seen.add(stop.id);
        acc.n += 1;
        acc.lon += stop.attributes.longitude;
        acc.lat += stop.attributes.latitude;
        st.lon = acc.lon / acc.n;
        st.lat = acc.lat / acc.n;
      }
    }
  }
  return net;
}

// dbt map Parquet (map_stations + line_stops + routes) -> the same shape as the board_data map block.
async function mapFromMarts(store) {
  const [stations, stops, routes, shapes] = await Promise.all([
    store.run("mapStations"),
    store.run("lineStops"),
    store.has("routes") ? store.run("routes") : Promise.resolve([]),
    store.has("lineShapes") ? store.run("lineShapes") : Promise.resolve([]),
  ]);
  const shapeOf = new Map((shapes || []).map((r) => [r.branch_route_id, r.shape]));
  if (!stations || !stations.length || !stops || !stops.length) return null;
  const colorOf = new Map((routes || []).map((r) => [r.route_id, r.route_color_hex]));
  const names = new Map((routes || []).map((r) => [r.route_id, r.display_name]));
  const dest = new Map(); // route_id -> [dir0, dir1]
  const branches = new Map(); // branch_route_id -> line
  for (const r of stops) {
    const d = dest.get(r.route_id) || [null, null];
    if (r.direction_destination && !d[r.direction_id]) d[r.direction_id] = r.direction_destination;
    dest.set(r.route_id, d);
    if (r.direction_id !== 0) continue;
    const key = r.branch_route_id || r.route_id;
    if (!branches.has(key)) {
      branches.set(key, { route_id: r.route_id, branch_route_id: key, color: r.route_color_hex || colorOf.get(r.route_id), route_name: names.get(r.route_id), stops: [] });
    }
    branches.get(key).stops.push(r.station_id);
  }
  for (const b of branches.values()) {
    b.direction_destinations = dest.get(b.route_id) || null;
    if (shapeOf.has(b.branch_route_id)) b[BOARD_KEYS.mapShape] = shapeOf.get(b.branch_route_id);
  }
  return { [BOARD_KEYS.mapStations]: stations, [BOARD_KEYS.mapLines]: [...branches.values()] };
}

// Route colours from dbt routes.parquet (`route_color_hex`, GTFS) override whatever the network
// source carried, so every element uses the same published colours. Missing column/rows: untouched.
export async function applyRouteColors(net, store) {
  if (!store || !store.has("routes")) return 0;
  const rows = await store.run("routes");
  let n = 0;
  for (const r of rows || []) {
    const c = normHex(r.route_color_hex);
    if (!c) continue;
    const route = net.routes.get(r.route_id);
    if (route) { route.color = c; n++; }
    else net.routes.set(r.route_id, { id: r.route_id, color: c, name: r.display_name || r.route_id, destinations: null });
  }
  for (const f of net.lineFeatures) {
    const c = normHex((rows || []).find((r) => r.route_id === f.properties.route_id)?.route_color_hex);
    if (c) f.properties.color = c;
  }
  return n;
}

// Priority: board_data.json map block -> dbt map Parquet -> MBTA V3 API (one request, only when
// there is no dbt map at all). Live trains are the only other API traffic.
export async function loadNetwork(board, store = null) {
  const map = board && board[BOARD_KEYS.map];
  if (map && Array.isArray(map[BOARD_KEYS.mapStations]) && map[BOARD_KEYS.mapStations].length) {
    const net = fromBoard(map);
    if (net.lineFeatures.length) return net;
  }
  if (store) {
    const present = await store.probe(board);
    if (present.mapStations && present.lineStops && (await store.init(board)) && store.has("mapStations", "lineStops")) {
      const m = await mapFromMarts(store);
      if (m) {
        const net = fromBoard(m);
        if (net.lineFeatures.length) { net.source = "dbt-parquet"; return net; }
      }
    }
  }
  return fromApi();
}

export const linesForStation = (st) => {
  const ids = new Set();
  for (const r of st.routeIds) {
    const l = lineOfRoute(r);
    if (l) ids.add(l.line_id);
  }
  return LINES.filter((l) => ids.has(l.line_id));
};
