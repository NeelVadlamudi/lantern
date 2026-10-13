// Every SQL statement and every expected dbt name lives in this file.
//
// Names match the contracted dbt marts (models/marts/_marts.yml) and the Parquet exports
// dbt writes to out/ (models/exports/board_*.sql). If a contracted name changes, change it
// here; nothing else in the board needs to change.

import { stretchMetric, HERO, CHARTS, FREEDOM_TRAIL } from "./config.js";

// ---------------------------------------------------------------- tables (one view per Parquet file)
export const TABLES = {
  lineDaily: "line_daily",           // route_id x service_date            (mart_line_daily_reliability)
  period: "line_periods",            // route_id x day_type x period        (mart_period_reliability, loaded window)
  stationDaily: "station_daily",     // station_id x line_id x service_date x period (mart_station_daily_reliability)
  station: "station_periods",        // station_id x line_id x day_type x period: gate-entry weights + typical gaps
  periods: "service_periods",        // service_period_id
  mapStations: "map_stations",       // station_id (fallback map only)
  lineStops: "line_stops",           // branch x direction x stop_order (fallback map only)
  lineShapes: "line_shapes",         // branch x direction x point_order (fallback map only)
  routes: "routes",                  // route_id
  // rider-time metrics (values not final)
  rtlDaily: "rider_time_lost_daily",   // service_date: rider time lost, wait/ride split, day_type
  rtlWeekly: "rider_time_lost_weekly", // week_start_date
  segments: "segments",                // segment_id: track stretch, geometry, loss rank, buffer, trend, cause
  lineBuffer: "line_buffer",           // line_id: typical vs bad trip per stretch
  stationTrend: "station_trend",       // station_id x line_id: last 14 days vs 28 before
  stationTimeLost: "station_time_lost",// station_id x line_id x day_type x period
  trainDelayDaily: "train_delay_daily", // service_date: measured train delay (late-only + net), system-wide
  serviceChanges: "service_changes",  // dbt: planned work per line-day (is_planned_change); optional
  suspensionGaps: "suspension_gaps",    // one row per gap over an hour (hook; not drawn yet)
  // dbt build a501be8
  lineDayMetrics: "line_day_metrics",       // scope_id x service_date x measure: value, num/den, typical median/p25/p75
  dayWorstSegments: "day_worst_segments",   // scope_id x service_date: top 3 stretches by train delay
  dayWorstStations: "day_worst_stations",   // scope_id x service_date: top 3 stations by long gaps
  lineHourHeatmap: "line_hour_heatmap",     // scope_id x service_date x service_hour, usual_* ratings
  delayHistogram: "delay_histogram",        // kind x scope_id x service_date x 1-min bin (open ends)
  trainDelayByLine: "train_delay_by_line",  // period_kind x route_id: share of train delay
  crDaily: "cr_daily",                      // CR route x service_date
  crMonthly: "cr_monthly",                  // CR scope x month
  surveyLines: "survey_lines",              // 2025 survey: scope x measure x category
  crShapes: "cr_line_shapes",               // line_shapes.parquet, mode = commuter_rail rows
  crStations: "cr_map_stations",            // map_stations.parquet, Commuter Rail stations
};

// Parquet file names under CONFIG.DATA_PATH. board_data.json `files` wins when present.
export const PARQUET_FILES = {
  lineDaily: "line_daily.parquet",
  period: "line_periods.parquet",
  stationDaily: "station_daily.parquet",
  station: "station_periods.parquet",
  periods: "service_periods.parquet",
  mapStations: "map_stations.parquet",
  lineStops: "line_stops.parquet",
  lineShapes: "line_shapes.parquet",
  routes: "routes.parquet",
  rtlDaily: "rider_time_lost_daily.parquet",
  rtlWeekly: "rider_time_lost_weekly.parquet",
  segments: "segments.parquet",
  lineBuffer: "line_buffer.parquet",
  stationTrend: "station_trend.parquet",
  stationTimeLost: "station_time_lost.parquet",
  trainDelayDaily: "train_delay_daily.parquet",
  serviceChanges: "service_changes.parquet",
  suspensionGaps: "suspension_gaps.parquet",
  lineDayMetrics: "line_day_metrics.parquet",
  dayWorstSegments: "day_worst_segments.parquet",
  dayWorstStations: "day_worst_stations.parquet",
  lineHourHeatmap: "line_hour_heatmap.parquet",
  delayHistogram: "delay_histogram.parquet",
  trainDelayByLine: "train_delay_by_line.parquet",
  crDaily: "cr_daily.parquet",
  crMonthly: "cr_monthly.parquet",
  surveyLines: "survey_lines.parquet",
  crShapes: "line_shapes.parquet",
  crStations: "map_stations.parquet",
};
// Loaded on first use only (large); MartStore.ensure(key).
// Loaded on first use only, so the first screen stays light (charts load when their plates near view).
export const LAZY_FILES = ["crDaily", "lineHourHeatmap", "delayHistogram", "crMonthly", "surveyLines",
  "dayWorstSegments", "dayWorstStations", "trainDelayByLine", "crShapes", "crStations"];

// Chart / Freedom Trail tables the dbt build publishes later: registered from config when a `file` is set.
const EXTRA_TABLES = {
  chartHistogram: CHARTS.histogram.file, chartDonut: CHARTS.donut.file, chartSurvey: CHARTS.survey.file,
  chartHourly: CHARTS.heatmap.hourly.file, freedomTrail: FREEDOM_TRAIL.file,
};
for (const [k, f] of Object.entries(EXTRA_TABLES)) if (f && /^[A-Za-z0-9_]+$/.test(f)) { TABLES[k] = f; PARQUET_FILES[k] = `${f}.parquet`; }

// Files only needed when board_data.json has no map block (skipped otherwise).
export const MAP_FALLBACK_FILES = ["mapStations", "lineStops", "lineShapes"];

// ---------------------------------------------------------------- columns
export const COLS = {
  routeId: "route_id",
  lineId: "line_id",
  branchRouteId: "branch_route_id",
  directionId: "direction_id",
  directionDestination: "direction_destination",
  stopOrder: "stop_order",
  pointOrder: "point_order",
  stationId: "station_id",
  stationName: "station_name",
  latitude: "latitude",
  longitude: "longitude",
  routeIds: "route_ids",
  routeColor: "route_color_hex",
  displayName: "display_name",
  serviceDate: "service_date",
  dayType: "day_type",
  periodId: "service_period_id",
  periodName: "service_period_name",
  periodStart: "start_minute",
  periodEnd: "end_minute",
  periodSort: "sort_order",
  // line_daily: additive counts (pool these, never average the ratios)
  tripsCompared: "trips_compared",
  lateTrips: "late_trips",
  tripExcessSum: "trip_excess_seconds_sum",
  tripScheduledSum: "trip_scheduled_seconds_sum",
  headwayObs: "headway_observations",
  longGaps: "long_gaps",
  // line_periods: ratios + weights (no additive sums in this export)
  lateTripShare: "late_trip_share",
  tripExcess: "avg_trip_excess_seconds",
  longGapShare: "long_gap_share",
  // station_daily: additive counts
  travelComparisons: "travel_comparisons",
  excessTravelSum: "excess_travel_seconds_sum",
  // station_periods
  medianHeadway: "median_headway_seconds",
  medianSchedHeadway: "median_scheduled_headway_seconds",
  hasRiderData: "has_rider_data",
  dailyEntries: "avg_daily_gated_entries",
};

// ---------------------------------------------------------------- board_data.json keys
export const BOARD_KEYS = {
  meta: "meta",
  meta_disclaimer: "disclaimer",
  meta_window: "service_date_window",       // { first, last, days }
  meta_holidays: "holidays",                // [{ date, name, in_service_window }]
  meta_thresholds: "thresholds",
  tiles: "tiles",                           // [{ id, value, display, ... }] (cross-check only)
  files: "files",                           // [{ file, bytes, rows }]
  map: "map",
  mapStations: "stations",                  // [{ station_id, name, lat, lon, route_ids, has_rider_data }]
  mapLines: "lines",                        // [{ route_id, branch_route_id, direction_id, destination, color, stops, shape: [[lon, lat]] }]
  mapShape: "shape",
  periods: "periods",
  coverage: "coverage",
  cov_byRoute: "by_route",                  // [{ route_id, display_name, share_without_any_schedule, ... }]
  cov_system: "system",
  cov_definitions: "definitions",
  cov_noGates: "stations_without_gated_entries", // { count, of_stations, station_ids, by_line }
  build: "build",
  build_generatedAt: "generated_at_utc",
  build_dbtVersion: "dbt_version",
  build_modelsByLayer: "models_by_layer",
  build_modelsTotal: "models_total",
  build_seeds: "seeds",
  build_snapshots: "snapshots",
  build_sources: "sources",
  build_testsTotal: "tests_total",
  build_passed: "passed",                   // every node that passed or built (explicit total)
  build_warned: "warned",
  build_errored: "errored",
  build_skipped: "skipped",
  build_nodesTotal: "nodes_total",
  build_nodesByType: "nodes_by_type",       // { model, test, seed, snapshot, unit_test, exposure }
  build_testsPassed: "tests_passed",
  build_testsWarned: "tests_warned",
  build_testsFailed: "tests_failed",
  build_contracted: "contracted_models",
  build_incremental: "incremental_models",
  build_edges: "layer_edges",
  build_docs: "docs",                       // { index: "dbt/index.html", lineage_anchor, overview_anchor }
  build_models: "models",
  decision: "decision",                     // { rider_time_lost, segments, line_buffer, cause_counts, getting_worse }
};

// Extra dbt files next to board_data.json.
export const EXTRA_FILES = {
  buildResults: "build_results.json",       // dbt run results, one row per node (status)
  durationCases: "duration_label_cases.json",
};

export const LAYERS = ["raw", "staging", "intermediate", "marts", "exports"];

// ---------------------------------------------------------------- SQL helpers
const q = (s) => `'${String(s).replace(/'/g, "''")}'`;
const inList = (arr) => arr.map(q).join(", ");
const wavg = (v, w) => `sum(${v} * ${w}) / nullif(sum(case when ${v} is not null then ${w} end), 0)`;
const ratio = (num, den) => `sum(${num})::double / nullif(sum(${den}), 0)`;

function where(parts) {
  const p = parts.filter(Boolean);
  return p.length ? `where ${p.join(" and ")}` : "";
}

// Date + day-type predicates for a daily table (day_type comes from dbt dim_dates, holidays
// included). dayType "all" keeps every service day.
// Stretch ranking from the configured metric. Missing rank/top columns are computed here
// (rank by value, highest first; top = rank <= 10); a missing share stays null.
const stretchCte = () => {
  const m = stretchMetric();
  const v = m.value || "null::double";
  const rank = m.rank || `case when ${v} is not null then rank() over (order by ${v} desc nulls last) end`;
  const top = m.top ? `coalesce(${m.top}, false)` : "coalesce(metric_rank <= 10, false)";
  return `with s0 as (select *, (${v})::double as metric_value, (${m.net || "null::double"})::double as metric_net, (${rank})::int as metric_rank from ${TABLES.segments}),
    s as (select *, ${top} as metric_top, ${m.share ? `(${m.share})::double` : "null::double"} as metric_share from s0)`;
};

const daily = (f, dayType, alias = "") => [
  f.dateFrom && `${alias}${COLS.serviceDate} >= ${q(f.dateFrom)}::date`,
  f.dateTo && `${alias}${COLS.serviceDate} <= ${q(f.dateTo)}::date`,
  dayType && dayType !== "all" && `${alias}${COLS.dayType} = ${q(dayType)}`,
  Number.isInteger(f.dow) && `dayofweek(${alias}${COLS.serviceDate}) = ${f.dow}`, // chart cross-filter (0 = Sunday)
];

// Station long-gap shares per (station, line, period) over the chosen days; the rider tile and the
// map multiply these by station_periods gate entries for the same station, line, day type and period.
const cellShares = (f, dayType) => `
    select ${COLS.stationId} as station_id, ${COLS.lineId} as line_id, ${COLS.periodId} as service_period_id,
           ${ratio(COLS.longGaps, COLS.headwayObs)} as long_gap_share
    from ${TABLES.stationDaily}
    ${where([
      ...daily(f, dayType),
      f.lineIds.length && `${COLS.lineId} in (${inList(f.lineIds)})`,
      f.periodId && `${COLS.periodId} = ${q(f.periodId)}`,
    ])}
    group by 1, 2, 3`;

const weights = (f) => `
    select ${COLS.stationId} as station_id, ${COLS.lineId} as line_id, ${COLS.periodId} as service_period_id,
           ${COLS.dailyEntries} as entries
    from ${TABLES.station}
    ${where([
      COLS.hasRiderData,
      `${COLS.dayType} = ${q(f.riderDayType)}`,
      f.lineIds.length && `${COLS.lineId} in (${inList(f.lineIds)})`,
      f.periodId && `${COLS.periodId} = ${q(f.periodId)}`,
    ])}`;

// filters: { routeIds, lineIds, dayType: all|weekday|saturday|sunday, riderDayType: weekday|saturday|sunday,
//            periodId|null, dateFrom, dateTo, stationId }
export const SQL = {
  mapStations: () => `
    select ${COLS.stationId} as station_id, ${COLS.stationName} as station_name,
           ${COLS.latitude} as latitude, ${COLS.longitude} as longitude, ${COLS.routeIds} as route_ids
    from ${TABLES.mapStations}`,

  lineStops: () => `
    select ${COLS.routeId} as route_id, ${COLS.branchRouteId} as branch_route_id,
           ${COLS.directionId} as direction_id, ${COLS.directionDestination} as direction_destination,
           ${COLS.stopOrder} as stop_order, ${COLS.stationId} as station_id, ${COLS.routeColor} as route_color_hex
    from ${TABLES.lineStops}
    order by branch_route_id, direction_id, stop_order`,

  lineShapes: () => `
    select ${COLS.branchRouteId} as branch_route_id, list([${COLS.longitude}, ${COLS.latitude}] order by ${COLS.pointOrder}) as shape
    from ${TABLES.lineShapes}
    where ${COLS.directionId} = 0
    group by 1`,

  routes: () => `
    select ${COLS.routeId} as route_id, ${COLS.routeColor} as route_color_hex, ${COLS.displayName} as display_name
    from ${TABLES.routes}`,

  dateRange: () => `
    select min(${COLS.serviceDate})::varchar as min_date, max(${COLS.serviceDate})::varchar as max_date
    from ${TABLES.lineDaily}`,

  // Late trips + extra time per run, pooled from additive counts (line x day grain).
  tripKpisByDate: (f) => `
    select
      ${ratio(COLS.lateTrips, COLS.tripsCompared)} as late_trip_share,
      ${ratio(COLS.tripExcessSum, COLS.tripsCompared)} as avg_trip_excess_seconds,
      ${ratio(COLS.tripExcessSum, COLS.tripScheduledSum)} as excess_share_of_scheduled,
      sum(${COLS.tripsCompared})::double as trips_compared,
      count(distinct ${COLS.serviceDate}) as service_days
    from ${TABLES.lineDaily}
    ${where([
      f.routeIds.length && `${COLS.routeId} in (${inList(f.routeIds)})`,
      ...daily(f, f.dayType),
      f.noPlannedLine && "coalesce(is_planned_change, false) = false", // the dbt build's rule: planned line-days left out
    ])}`,

  // One time of day: the period mart covers the loaded window and has no service date.
  tripKpisByPeriod: (f) => `
    select
      ${wavg(COLS.lateTripShare, COLS.tripsCompared)} as late_trip_share,
      ${wavg(COLS.tripExcess, COLS.tripsCompared)} as avg_trip_excess_seconds,
      null as excess_share_of_scheduled,
      sum(${COLS.tripsCompared})::double as trips_compared
    from ${TABLES.period}
    ${where([
      f.routeIds.length && `${COLS.routeId} in (${inList(f.routeIds)})`,
      f.dayType !== "all" && `${COLS.dayType} = ${q(f.dayType)}`,
      `${COLS.periodId} = ${q(f.periodId)}`,
    ])}`,

  // Long gaps: departures after a gap > 1.5x scheduled, pooled over station x line x day x period.
  longGaps: (f) => `
    select ${ratio(COLS.longGaps, COLS.headwayObs)} as long_gap_share,
           sum(${COLS.headwayObs})::double as headway_observations
    from ${TABLES.stationDaily}
    ${where([
      ...daily(f, f.dayType),
      f.lineIds.length && `${COLS.lineId} in (${inList(f.lineIds)})`,
      f.periodId && `${COLS.periodId} = ${q(f.periodId)}`,
      f.noPlannedStation && "coalesce(is_planned_change, false) = false",
    ])}`,

  // Gate entries in long gaps for an average day of riderDayType (as mart_station_overview does for
  // weekdays): sum over station x line x period of gate entries x long-gap share.
  entriesInLongGaps: (f) => `
    with s as (${cellShares(f, f.riderDayType)}), w as (${weights(f)})
    select sum(w.entries * s.long_gap_share) as entries_in_long_gaps,
           sum(case when s.long_gap_share is not null then w.entries end) as gated_entries
    from w left join s using (station_id, line_id, service_period_id)`,

  // Map: per station, entries in long gaps (ranked for shading) on the same basis as the tile.
  stationShading: (f) => `
    with s as (${cellShares(f, f.riderDayType)}), w as (${weights(f)})
    select w.station_id,
           sum(w.entries * s.long_gap_share) as entries_in_long_gaps,
           sum(case when s.long_gap_share is not null then w.entries end) as gated_entries
    from w left join s using (station_id, line_id, service_period_id)
    group by 1`,

  // Time-of-day strip: long-gap share per period over the chosen dates and day type.
  periodStrip: (f) => `
    select d.${COLS.periodId} as service_period_id, d.${COLS.periodName} as service_period_name,
           d.${COLS.periodStart} as start_minute, d.${COLS.periodEnd} as end_minute, d.${COLS.periodSort} as sort_order,
           g.long_gap_share
    from ${TABLES.periods} d
    left join (
      select ${COLS.periodId} as service_period_id, ${ratio(COLS.longGaps, COLS.headwayObs)} as long_gap_share
      from ${TABLES.stationDaily}
      ${where([...daily(f, f.dayType), f.lineIds.length && `${COLS.lineId} in (${inList(f.lineIds)})`])}
      group by 1
    ) g on g.service_period_id = d.${COLS.periodId}
    order by sort_order`,

  // Periods only (no data) for first paint.
  periodList: () => `
    select ${COLS.periodId} as service_period_id, ${COLS.periodName} as service_period_name,
           ${COLS.periodStart} as start_minute, ${COLS.periodEnd} as end_minute, ${COLS.periodSort} as sort_order
    from ${TABLES.periods} order by sort_order`,

  // Station drawer: one station by line and period over the chosen dates and day type.
  stationDetail: (f) => `
    with d as (
      select ${COLS.lineId} as line_id, ${COLS.periodId} as service_period_id,
             ${ratio(COLS.excessTravelSum, COLS.travelComparisons)} as avg_excess_travel_seconds,
             ${ratio(COLS.longGaps, COLS.headwayObs)} as long_gap_share,
             sum(${COLS.headwayObs})::double as headway_observations
      from ${TABLES.stationDaily}
      ${where([`${COLS.stationId} = ${q(f.stationId)}`, ...daily(f, f.dayType)])}
      group by 1, 2
    ), r as (
      select ${COLS.lineId} as line_id, ${COLS.periodId} as service_period_id,
             case when ${COLS.hasRiderData} then ${COLS.dailyEntries} end as daily_entries
      from ${TABLES.station}
      where ${COLS.stationId} = ${q(f.stationId)} and ${COLS.dayType} = ${q(f.riderDayType)}
    )
    select d.*, r.daily_entries, p.${COLS.periodName} as service_period_name, p.${COLS.periodSort} as sort_order
    from d
    left join r using (line_id, service_period_id)
    left join ${TABLES.periods} p on p.${COLS.periodId} = d.service_period_id
    order by d.line_id, p.${COLS.periodSort}`,

  // Station drawer summary: gate entries in long gaps on the rider-day basis.
  stationExposure: (f) => `
    with s as (${cellShares({ ...f, lineIds: [], periodId: null }, f.riderDayType)}),
         w as (${weights({ ...f, lineIds: [], periodId: null })})
    select sum(w.entries * s.long_gap_share) as entries_in_long_gaps,
           sum(case when s.long_gap_share is not null then w.entries end) as gated_entries
    from w left join s using (station_id, line_id, service_period_id)
    where w.station_id = ${q(f.stationId)}`,

  // ---------------------------------------------------------------- charts (config CHARTS)
  // Late runs by line and service date (line_daily). f: shared filters minus the chart's own date pick.
  chartDaily: (f) => {
    const C = CHARTS.daily.columns;
    return `
    select ${C.date}::varchar as d, ${C.line} as line_id, any_value(${C.dayType}) as day_type,
           sum(${C.late})::double as late, sum(${C.compared})::double as compared
    from ${TABLES[CHARTS.daily.table]}
    ${where([...daily(f, f.dayType), f.lineIds.length && `${C.line} in (${inList(f.lineIds)})`])}
    group by 1, 2 order by 1, 2`;
  },
  // Long-gap share by day of week x time-of-day period (station_daily); f minus its own cell pick.
  chartHeat: (f) => {
    const C = CHARTS.heatmap.columns;
    return `
    select dayofweek(${C.date})::int as dow, ${C.period} as period_id,
           sum(${C.num})::double as num, sum(${C.den})::double as den, count(distinct ${C.date})::int as days
    from ${TABLES[CHARTS.heatmap.table]}
    ${where([...daily({ ...f, dow: null }, f.dayType), f.lineIds.length && `${C.line} in (${inList(f.lineIds)})`, f.stationId && `${C.station} = ${q(f.stationId)}`])}
    group by 1, 2`;
  },
  freedomTrail: () => {
    const C = FREEDOM_TRAIL.columns;
    return `select * from ${TABLES.freedomTrail} order by ${C.order}`;
  },

  // ---------------------------------------------------------------- main number: daily series
  // Measured train delay per service date (system-wide; config HERO.daily). Whole window.
  trainDelaySeries: () => `
    select ${HERO.daily.date}::varchar as d, ${HERO.daily.dayType} as day_type,
           ${HERO.daily.late}::double as late, ${HERO.daily.net}::double as net
    from ${TABLES[HERO.daily.table]}
    order by 1`,

  // ---------------------------------------------------------------- rider time lost
  // Hero, system-wide: average day of heroDay over the chosen dates (daily file).
  heroByDate: (f) => `
    select avg(rider_time_lost_seconds) as rider_time_lost_seconds,
           avg(rider_wait_time_lost_seconds) as wait_seconds,
           avg(rider_ride_time_lost_seconds) as ride_seconds,
           avg(gated_entries) as gated_entries,
           count(rider_time_lost_seconds)::int as days
    from ${TABLES.rtlDaily}
    ${where([...daily(f, f.heroDay), "rider_time_lost_seconds is not null"])}`,

  // Hero for some lines or one time of day: station x line x day_type x period (loaded window).
  // No gate-entry total here: station_time_lost entries don't add up to the daily file's
  // denominator, so the board shows no per-trip figure on this path.
  // heroDay "all": each day type's average weighted by its number of days with rider data.
  heroByCell: (f) => {
    const cells = where([
      f.heroDay !== "all" && `${COLS.dayType} = ${q(f.heroDay)}`,
      `${COLS.dayType} <> 'holiday'`, // no holiday rider weights in station_time_lost (dbt): hidden here only
      f.lineIds.length && `${COLS.lineId} in (${inList(f.lineIds)})`,
      f.periodId && `${COLS.periodId} = ${q(f.periodId)}`,
    ]);
    if (f.heroDay !== "all") return `select sum(avg_daily_rider_time_lost_seconds) as rider_time_lost_seconds from ${TABLES.stationTimeLost} ${cells}`;
    return `
    with n as (select ${COLS.dayType} as day_type, count(*) as days from ${TABLES.rtlDaily} where rider_time_lost_seconds is not null group by 1),
         c as (select ${COLS.dayType} as day_type, sum(avg_daily_rider_time_lost_seconds) as r from ${TABLES.stationTimeLost} ${cells} group by 1)
    select sum(c.r * n.days) / sum(case when c.r is not null then n.days end) as rider_time_lost_seconds
    from c join n using (day_type)`;
  },

  heroWeekly: () => `
    select week_start_date::varchar as week_start, week_end_date::varchar as week_end,
           first_service_date::varchar as first_date, last_service_date::varchar as last_date,
           is_complete_week, weekdays_with_rider_data::int as weekdays,
           avg_weekday_rider_time_lost_seconds as weekday_seconds,
           avg_daily_rider_time_lost_seconds as daily_seconds
    from ${TABLES.rtlWeekly}
    order by week_start_date`,

  // Track stretches for the map and lists (whole window; segments carry no date grain).
  // Ranked by the configured STRETCH_METRIC (config.js): metric_value / metric_rank / metric_top / metric_share.
  segments: () => `
    ${stretchCte()}
    select segment_id, line_id, route_id, direction_id, from_station_id, from_station_name,
           to_station_id, to_station_name, segment_name, geometry,
           metric_value, metric_net, metric_rank, metric_top, metric_share,
           is_getting_worse, delta_excess_seconds
    from s`,

  segmentDetail: (f) => `
    ${stretchCte()}
    select * exclude (geometry), recent_start_date::varchar as recent_from, recent_end_date::varchar as recent_to,
           prior_start_date::varchar as prior_from, prior_end_date::varchar as prior_to,
           (select count(*) from s where metric_rank is not null)::int as ranked
    from s where segment_id = ${q(f.segmentId)}`,

  lineBuffer: (f) => `select * from ${TABLES.lineBuffer} where ${COLS.lineId} = ${q(f.lineId)}`,

  worseSegments: () => `
    select segment_id, segment_name, line_id, delta_excess_seconds, runs_recent, runs_prior,
           recent_start_date::varchar as recent_from, recent_end_date::varchar as recent_to,
           prior_start_date::varchar as prior_from, prior_end_date::varchar as prior_to
    from ${TABLES.segments} where is_getting_worse
    order by delta_excess_seconds desc`,

  worseStations: () => `
    select station_id, station_name, line_id, delta_excess_seconds, departures_recent, departures_prior,
           recent_start_date::varchar as recent_from, recent_end_date::varchar as recent_to,
           prior_start_date::varchar as prior_from, prior_end_date::varchar as prior_to
    from ${TABLES.stationTrend} where is_getting_worse
    order by delta_excess_seconds desc`,

  stationTrend: (f) => `
    select line_id, excess_per_rider_recent_seconds as recent_seconds, excess_per_rider_prior_seconds as prior_seconds,
           delta_excess_seconds, is_getting_worse, meets_volume_threshold,
           recent_start_date::varchar as recent_from, recent_end_date::varchar as recent_to,
           prior_start_date::varchar as prior_from, prior_end_date::varchar as prior_to
    from ${TABLES.stationTrend} where ${COLS.stationId} = ${q(f.stationId)} order by line_id`,

  stationTimeLost: (f) => `
    select sum(avg_daily_rider_time_lost_seconds) as rider_time_lost_seconds
    from ${TABLES.stationTimeLost}
    where ${COLS.stationId} = ${q(f.stationId)} and ${COLS.dayType} = ${q(f.cellDay)} and ${COLS.dayType} <> 'holiday'`,

  // Line comparison: share of scheduled run time (primary), seconds per run (secondary).
  lineCompare: (f) => `
    select ${COLS.routeId} as route_id, any_value(${COLS.lineId}) as line_id, any_value(${COLS.displayName}) as display_name,
           ${ratio(COLS.tripExcessSum, COLS.tripScheduledSum)} as excess_share_of_scheduled,
           ${ratio(COLS.tripExcessSum, COLS.tripsCompared)} as avg_trip_excess_seconds,
           ${ratio(COLS.lateTrips, COLS.tripsCompared)} as late_trip_share,
           ${ratio(COLS.longGaps, COLS.headwayObs)} as long_gap_share,
           sum(${COLS.tripsCompared})::double as trips_compared
    from ${TABLES.lineDaily}
    ${where(daily(f, f.dayType))}
    group by 1
    order by excess_share_of_scheduled desc nulls last`,
};
