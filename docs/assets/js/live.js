// Live train positions from the MBTA V3 API. One request per poll (include=stop,route resolves
// platform names, parent stations and route names/colours in the same response). Subway (route
// types 0, 1) and Commuter Rail (type 2) share that single request. Pauses while the tab is hidden.
import { CONFIG, COMMUTER_RAIL, normHex } from "./config.js";
import { mbta, ApiError, indexIncluded } from "./api.js";

const STATUS = {
  INCOMING_AT: "Arriving at",
  STOPPED_AT: "Stopped at",
  IN_TRANSIT_TO: "Heading to",
};

export function statusText(v) {
  const verb = STATUS[v.status] || "Near";
  return v.stopName ? `${verb} ${v.stopName}` : "Between stations";
}

export class LiveTrains {
  constructor({ onData, onState }) {
    this.onData = onData;
    this.onState = onState;
    this.interval = Math.max(15000, CONFIG.POLL_MS);
    this.delay = this.interval;
    this.timer = null;
    this.inflight = null;
    this.lastOkAt = 0;      // client clock when the last good response arrived
    this.lastRequestAt = 0;
    this.state = "starting";
    this.retryAt = 0;
    document.addEventListener("visibilitychange", () => this.onVisibility());
  }

  start() {
    if (document.hidden) return this.setState("paused");
    this.poll();
  }

  setState(state) {
    this.state = state;
    this.onState && this.onState(this);
  }

  schedule(ms) {
    clearTimeout(this.timer);
    this.retryAt = Date.now() + ms;
    this.timer = setTimeout(() => this.poll(), ms);
  }

  onVisibility() {
    if (document.hidden) {
      clearTimeout(this.timer);
      this.timer = null;
      if (this.inflight) this.inflight.abort();
      this.setState("paused");
      return;
    }
    // Back in view: refresh now if the last request is at least one interval old,
    // otherwise wait out the remainder so we never poll faster than the interval.
    const since = Date.now() - this.lastRequestAt;
    this.schedule(Math.max(0, this.delay - since));
    this.setState(this.lastOkAt ? "live" : "starting");
  }

  async poll() {
    if (document.hidden) return;
    this.lastRequestAt = Date.now();
    this.inflight = new AbortController();
    try {
      const doc = await mbta(
        "/vehicles",
        {
          "filter[route_type]": `0,1,${COMMUTER_RAIL.ROUTE_TYPE}`,
          include: "stop,route",
          "fields[vehicle]": "latitude,longitude,bearing,current_status,updated_at,label,direction_id",
          "fields[stop]": "name",
          "fields[route]": "long_name,color,type,direction_destinations",
        },
        { signal: this.inflight.signal }
      );
      const inc = indexIncluded(doc);
      const vehicles = [];
      for (const v of doc.data || []) {
        const a = v.attributes;
        if (a.latitude == null || a.longitude == null) continue;
        const stopRef = v.relationships.stop && v.relationships.stop.data;
        const stop = stopRef && inc.get(`stop:${stopRef.id}`);
        const parent = stop && stop.relationships.parent_station && stop.relationships.parent_station.data;
        const routeId = v.relationships.route && v.relationships.route.data ? v.relationships.route.data.id : null;
        const route = routeId ? inc.get(`route:${routeId}`) : null;
        const ra = (route && route.attributes) || {};
        vehicles.push({
          id: v.id,
          routeId,
          routeType: Number.isFinite(ra.type) ? ra.type : null,
          routeName: ra.long_name || null,
          routeColor: normHex(ra.color),
          routeDestinations: Array.isArray(ra.direction_destinations) ? ra.direction_destinations : null,
          lon: a.longitude,
          lat: a.latitude,
          bearing: a.bearing || 0,
          status: a.current_status,
          label: a.label,
          directionId: a.direction_id,
          updatedAt: a.updated_at,
          stopId: stopRef ? stopRef.id : null,
          stationId: parent ? parent.id : null, // MBTA place-xxx, joins to dbt station_id
          stopName: stop ? stop.attributes.name : null,
        });
      }
      this.lastOkAt = Date.now();
      this.delay = this.interval;
      this.onData(vehicles);
      this.setState("live");
      this.schedule(this.delay);
    } catch (err) {
      if (err.name === "AbortError") return;
      const hinted = err instanceof ApiError && err.retryAfterMs ? err.retryAfterMs : 0;
      this.delay = Math.min(CONFIG.BACKOFF_MAX_MS, Math.max(this.delay * 2, hinted, this.interval * 2));
      this.setState(err instanceof ApiError && err.status === 429 ? "limited" : "error");
      this.schedule(this.delay);
    } finally {
      this.inflight = null;
    }
  }
}
