// Single place for names, paths and limits. Rename the board by editing TITLE only.
export const CONFIG = Object.freeze({
  TITLE: "Lantern",
  SUBTITLE: "Where the T runs late, from recorded train runs.",

  // All dbt output is read from here: board_data.json + mart Parquet files.
  // At publish, docs/data/ is filled from the dbt out/ folder (dbt writes there).
  DATA_PATH: "./data/",
  BOARD_FILE: "board_data.json",

  // dbt docs site, published next to the board at docs/dbt/ (build.docs.index wins when present).
  DOCS_INDEX: "./dbt/index.html",

  REPO_URL: "https://github.com/NeelVadlamudi/lantern",
  REPO_LABEL: "Source repository",

  // Used only if board_data.json meta.disclaimer is missing.
  DISCLAIMER: "Public MBTA data. Live positions from the MBTA V3 API. Not affiliated with the MBTA.",

  // MBTA V3 API. Anonymous use is limited to 20 requests per minute per IP.
  API_BASE: "https://api-v3.mbta.com",
  SUBWAY_ROUTES: ["Red", "Mattapan", "Orange", "Green-B", "Green-C", "Green-D", "Green-E", "Blue"],
  POLL_MS: 15000,            // never below 15 s
  BACKOFF_MAX_MS: 240000,    // ceiling after repeated 429s/errors
  STALE_MS: 60000,           // freshness chip dims after this
  API_BUDGET_PER_MIN: 10,    // client-side cap, half the anonymous limit

  // Map
  CENTER: [-71.075, 42.345],
  ZOOM: 11.2,
  TWEEN_MS: 1400,
});

// Line chips. line_id matches dbt dim_routes.line_id; route_ids match GTFS and the live feed.
// Line colours come from dbt at runtime (routes.parquet `route_color_hex`, GTFS). `fallbackColor`
// is used ONLY when that column is missing; the values are the published MBTA colours.
export const LINES = Object.freeze([
  { line_id: "Red", label: "Red", route_ids: ["Red"], fallbackColor: "#DA291C" },
  { line_id: "Mattapan", label: "Mattapan", route_ids: ["Mattapan"], fallbackColor: "#DA291C" },
  { line_id: "Orange", label: "Orange", route_ids: ["Orange"], fallbackColor: "#ED8B00" },
  { line_id: "Green", label: "Green", route_ids: ["Green-B", "Green-C", "Green-D", "Green-E"], fallbackColor: "#00843D" },
  { line_id: "Blue", label: "Blue", route_ids: ["Blue"], fallbackColor: "#003DA5" },
]);

// "all" = every service day (holidays included), the basis of the dbt build's headline tiles.
// Gate-entry figures always describe an average weekday, Saturday or Sunday ("all" uses weekday).
export const DAY_TYPES = Object.freeze([
  { id: "all", label: "All days", short: "All" },
  { id: "weekday", label: "Weekday", short: "Wkdy" },
  { id: "saturday", label: "Saturday", short: "Sat" },
  { id: "sunday", label: "Sunday", short: "Sun" },
]);

export const lineOfRoute = (routeId) =>
  LINES.find((l) => l.route_ids.includes(routeId)) || null;

// "DA291C", "#DA291C", " #da291c " -> "#DA291C"; anything else -> null.
export function normHex(c) {
  const h = String(c ?? "").trim().replace(/^#/, "");
  return /^[0-9a-fA-F]{6}$/.test(h) ? `#${h.toUpperCase()}` : null;
}
export const fallbackLineColor = (lineId) => (LINES.find((l) => l.line_id === lineId) || {}).fallbackColor || null;

// Hotspot / selection / alert emphasis: iron-gall ink ("Boston, 1775" theme). Never a hue, so it
// can't be confused with any MBTA line colour; alerts add a small symbol as well.
export const HOT = "#2B2118";
export const hotRgba = (a) => `rgba(43, 33, 24, ${a})`;

// ---------------------------------------------------------------- track stretch ranking
// One switch picks the metric that ranks stretches (map numbered top 10, card 5, Top 10 list, drawer).
// Columns in segments.parquet (ranked by recorded train delay). Values in
// seconds; null = not available (rank / top are then computed on the board from `value`).
export const STRETCH_METRICS = Object.freeze({
  train_delay: {
    value: "train_delay_weekday_seconds",        // late time only, per average weekday
    net: "train_delay_weekday_net_seconds",      // early runs offset late ones
    rank: "loss_rank",
    top: "is_top_10",
    share: "share_of_segment_train_delay",
    topShareKey: "top_10_share_of_segment_train_delay", // board_data decision.segments (cross-check only)
    label: "Train delay",
    legend: "recorded train delay",
    valueNote: "late time per average weekday, recorded",
    shareNote: "Share = part of all stretch train delay.",
    shareOf: "of all stretch train delay",
  },
});
export const STRETCH_METRIC = "train_delay";
export const stretchMetric = () => STRETCH_METRICS[STRETCH_METRIC];

// Terminal stretches: dbt flags. Departure-terminal stretches carry the platform wait separately
// (terminal_hold_*); arrival-terminal stretches can't split it (only arrival is recorded).
export const TERMINAL = Object.freeze({
  departure: "is_terminal_departure",
  arrival: "is_terminal_arrival",
  split: "terminal_time_split",                 // "departure_hold_split" | "arrival_not_split" | null
  splitValues: ["departure_hold_split"],        // anything else (false/null/"arrival_not_split") = not split
  holdWeekday: "terminal_hold_weekday_seconds",
  holdPerRun: "terminal_hold_per_run_seconds",
  notSplitNote: "Ends at the terminal: only arrival is recorded, so wait time can't be split.",
});
// Fallback only when the flag columns are missing.
export const TERMINAL_STATIONS = Object.freeze({
  "place-asmnl": "Ashmont", "place-alfcl": "Alewife", "place-brntn": "Braintree", "place-bomnl": "Bowdoin",
  "place-wondl": "Wonderland", "place-forhl": "Forest Hills", "place-ogmnl": "Oak Grove", "place-matt": "Mattapan",
  "place-hsmnl": "Heath Street", "place-river": "Riverside", "place-lake": "Boston College",
  "place-clmnl": "Cleveland Circle", "place-unsqu": "Union Square", "place-mdftf": "Medford/Tufts",
});

// ---------------------------------------------------------------- main number: measured train delay
// board_data.json tile . Weekday fields; all-days fields when "All days" is on.
// the dbt build's *_label fields are used only to cross-check duration.js (console warning on mismatch).
export const HERO = Object.freeze({
  tile: "train_delay_weekday",
  weekday: { total: "value_seconds", totalLabel: "value_label", net: "net_seconds", netLabel: "net_label",
    perRun: "per_run_seconds", perRunLabel: "per_run_label", netPerRun: "net_per_run_seconds", netPerRunLabel: "net_per_run_label",
    runs: "runs", days: "weekdays" },
  all: { total: "all_days_value_seconds", totalLabel: "all_days_value_label", net: "all_days_net_seconds", netLabel: "all_days_net_label",
    perRun: "all_days_per_run_seconds", perRunLabel: "all_days_per_run_label", netPerRun: "all_days_net_per_run_seconds",
    netPerRunLabel: "all_days_net_per_run_label", runs: "all_days_runs", days: "service_dates" },
  note: "Time trains wait at end-of-line platforms is kept separate, not counted as delay.",
  // Daily series (sparkline): train_delay_daily.parquet
  daily: { table: "trainDelayDaily", date: "service_date", dayType: "day_type", late: "train_delay_seconds", net: "train_delay_net_seconds" },
});

// ---------------------------------------------------------------- stretch drawer: measured delay rows
// Each row shows the first listed column present in the stretch's row (seconds).
export const STRETCH_DELAY_ROWS = Object.freeze([
  { key: "net", columns: ["train_delay_weekday_net_seconds"], label: "Net per weekday (early runs offset late ones)", signed: true },
  { key: "hold", columns: ["terminal_hold_weekday_seconds"], label: "Waiting at {terminal} before leaving, per weekday (kept separate)", terminalOnly: "departure" },
  { key: "holdRun", columns: ["terminal_hold_per_run_seconds"], label: "Waiting at {terminal} per run (kept separate)", terminalOnly: "departure" },
]);

// ---------------------------------------------------------------- Commuter Rail (live trains only)
// CR vehicles arrive in the SAME /vehicles request as the subway (route_type 2 added to the filter).
// They are drawn only in the "Subway + Commuter Rail" view and never feed any subway figure.
export const COMMUTER_RAIL = Object.freeze({
  ROUTE_TYPE: 2,
  LINE_ID: "CR",
  LABEL: "Commuter Rail",
  // Official MBTA Commuter Rail purple; used only if no route colour comes from data
  // (routes.parquet route_color_hex first, then the API route colour in the same response).
  FALLBACK_COLOR: "#80276C",
  // Geographic extent of the CR network (outer terminals: Wickford Junction, Worcester, Wachusett,
  // Newburyport, Kingston, Middleborough) used for the "+ Commuter Rail" fit until dbt CR stops exist.
  BOUNDS: [[-71.87, 41.58], [-70.76, 42.81]],
  // HOOK for the dbt build's CR track shapes and stops (not published yet): TABLES/PARQUET keys to read when
  // they land; the map draws them via BoardMap.setCommuterRailNetwork(lineFeatures, stations).
  SHAPES_TABLE: null,
  STOPS_TABLE: null,
});
export const isCommuterRail = (routeId) => /^CR-/.test(String(routeId || ""));

// ---------------------------------------------------------------- service day label ({day_label})
// "Yesterday" only when the file's service date = today (America/New_York) − 1 at view time; else
// "Mon, Oct 5" (see daylabel.js). Source: board_data.json meta.service_date_window.last; the latest
// service_date in line_daily is only a cross-check (console warning when they disagree).
export const SERVICE_DATE = Object.freeze({
  json: "meta.service_date_window.last",
  // The latest day's own date (the dbt build's latest_day block) wins when present, so the date shown always
  // matches the latest-day figures beside it.
  latestJson: "latest_day.service_date",
  crossCheck: { query: "select max(service_date)::varchar as v from {lineDaily}" },
});

// ---------------------------------------------------------------- insight cards (left panel)
// Each card: question (mono), answer (sentence; {tokens} render from data, larger numerals), means (muted),
// note (small mono), chips, visual, map focus, tokens; optional `day` variant for the latest-day view.
//
// Token: { source, format } or { derive }.
//   source: { json: "path[key=value].field" }            board_data.json (one exact match)
//         | { table: "<TABLES key>", column, where: {} } one Parquet row, one column
//         | { query: "select ... as v from {tableKey}" } SQL returning exactly one row
//           ({service_date}, {window_first}, {window_last} = board_data meta values, quoted)
//         + rows: true -> every row (for sparklines)
//   format: percent {decimals} (share 0–1 ×100) | duration {signed} (duration.js, exact seconds on hover)
//         | count | number {decimals} | text | daytype_plural | date_range ("first|last") | rows
//   derive: { from, as: "one_in_n" }                 "1 in N", N = 1/share rounded (only where listed)
//         | { from, against, as: "compare", words: { higher, lower, same } }  compares displayed values
// Template extras: {day_label} ("Yesterday" / "On Mon, Oct 5" at a sentence start, lower case inside),
//   {day_label_sentence} (always the sentence form). A "%" right after a token joins its number.
// chips: [{ text, basis, at: "answer" | "means" }]: `at` puts the chip right under that figure.
// Any missing/null/ambiguous token -> the card shows CARD_WAITING. Never an estimate or stale value.
// visual: dots {token, dots, color, caption} | bars {bars: [{label, token}], marker, color}
//   | spark {token (rows), x, series: [{key, dim}], fields: {col: format}, tip: [summary, detail], caption}
//   | top10 {metric, footer}
// focus: { lines: [...], segments: [...] | {query}, stations: [...] | {json} | {query}, note }
export const CARD_WAITING = "Waiting for the checked figure";

const TD = "tiles[id=train_delay_weekday]";
const LATE = { source: { json: "meta.thresholds.late_trip_seconds" }, format: { type: "duration" } };
const GAP_RATIO = { source: { json: "meta.thresholds.long_gap_ratio" }, format: { type: "number", decimals: 1 } };
// Ashmont -> Shawmut, matched by stations (stable across rebuilds; the segment hash may change).
const ASHMONT_SHAWMUT = "from_station_id = 'place-asmnl' and to_station_id = 'place-smmnl' and line_id = 'Red'";
const ash = (col) => ({ query: `select ${col} as v from {segments} where ${ASHMONT_SHAWMUT}` });
// Red Line, one service date / same day type in the window (line_daily: route x service_date).
const RED_DAY = "route_id = 'Red' and service_date = {service_date}::date";
const RED_SAME_TYPE = `route_id = 'Red' and service_date between {window_first}::date and {window_last}::date
  and day_type = (select day_type from {lineDaily} where ${RED_DAY})`;
const ALL_DAY = "service_date = {service_date}::date";
// line_day_metrics: one scope (route or "system") x one measure on the latest service date.
const LDM = (scope, measure) => `scope_id = '${scope}' and measure = '${measure}' and service_date = {service_date}::date`;

export const INSIGHT_CARDS = Object.freeze([
  {
    id: "train_delay",
    caption: "Plate II. Measured train delay: every run against its timetable.",
    question: "How late do trains run?",
    answer: "On an average weekday, each train run between two stops took {per_run} longer than scheduled, counting late time only ({net_per_run} net of early runs).",
    means: "Across about {runs} runs a weekday, that adds up to {total} of train time over schedule ({total_net} net). A typical weekday: {td_p25} to {td_p75} per run (p25 to p75 of {td_days} weekdays).",
    note: "Time trains wait at end-of-line platforms is kept separate, not counted as delay.",
    chips: [{ text: "Measured · train runs", basis: "weekdays" }],
    visual: {
      type: "spark", token: "daily", x: "d", series: [{ key: "late" }, { key: "net", dim: true }],
      fields: { d: "date", late: "duration", net: "duration_signed", day_type: "text" },
      tip: ["{d}: {late} of train time over schedule, late time only", "Net {net} · {day_type}"],
      caption: "Each day: late time only (solid) and net (faint)",
    },
    tokens: {
      per_run: { source: { json: `${TD}.per_run_seconds` }, format: { type: "duration" } },
      td_p25: { source: { json: `${TD}.typical_range.per_run_p25_seconds` }, format: { type: "duration" } },
      td_p75: { source: { json: `${TD}.typical_range.per_run_p75_seconds` }, format: { type: "duration" } },
      td_days: { source: { json: `${TD}.typical_range.weekdays` }, format: { type: "count" } },
      net_per_run: { source: { json: `${TD}.net_per_run_seconds` }, format: { type: "duration" } },
      runs: { source: { json: `${TD}.runs` }, format: { type: "count" } },
      total: { source: { json: `${TD}.value_seconds` }, format: { type: "duration" } },
      total_net: { source: { json: `${TD}.net_seconds` }, format: { type: "duration" } },
      daily: { source: { query: "select service_date::varchar as d, day_type, train_delay_seconds as late, train_delay_net_seconds as net from {trainDelayDaily} order by 1", rows: true }, format: { type: "rows" } },
    },
    day: {
      answer: "{day_label_sentence}, each train run between two stops took {d_per_run} longer than scheduled, counting late time only.",
      means: "Across {d_runs} runs compared, that adds up to {d_total} of train time over schedule ({d_net} net).",
      note: "Time trains wait at end-of-line platforms is kept separate, not counted as delay.",
      chips: [{ text: "Measured · train runs" }],
      visual: {},
      tokens: {
        d_per_run: { source: { query: `select train_delay_per_run_seconds as v from {trainDelayDaily} where ${ALL_DAY}` }, format: { type: "duration" } },
        d_runs: { source: { query: `select runs_compared as v from {trainDelayDaily} where ${ALL_DAY}` }, format: { type: "count" } },
        d_total: { source: { query: `select train_delay_seconds as v from {trainDelayDaily} where ${ALL_DAY}` }, format: { type: "duration" } },
        d_net: { source: { query: `select train_delay_net_seconds as v from {trainDelayDaily} where ${ALL_DAY}` }, format: { type: "duration" } },
      },
    },
  },
  {
    id: "slow_or_unpredictable",
    caption: "Plate III. How often a trip falls well behind, and the two lines that fall behind most.",
    question: "How often is a train trip badly late?",
    answer: "Over all days, {pct_late}% of trips ({late} of {compared}) were more than {late_threshold} late (a typical day: {lt_p25}% to {lt_p75}%, p25 to p75 of {lt_days} days), and the average trip took {avg_excess} ({avg_excess_s} s) longer than scheduled.",
    // Worst line: the dbt build's worst_line tile, its own sentence and tie rule (day-paired test); the page adds no
    // ranking or tie logic of its own.
    means: "On weekdays it's {pct_late_wd}% late and {avg_excess_wd} ({avg_excess_wd_s} s) over. Worst line: {wl_verdict}. {wl_sentence}",
    note: "Tie test: {wl_rule}",
    chips: [{ text: "Measured · train runs", basis: "all days" }],
    visual: {
      type: "bars", color: "line:Red",
      bars: [{ labelToken: "wl_a", token: "a_pct", colorToken: "wl_a_id" }, { labelToken: "wl_b", token: "b_pct", colorToken: "wl_b_id" }],
    },
    focus: { lines: ["Red", "Green"], note: "Map: the two lines most often late" },
    tokens: {
      pct_late: { source: { json: "tiles[id=late_trip_share].value" }, format: { type: "percent", decimals: 1 } },
      lt_p25: { source: { json: "tiles[id=late_trip_share].typical_range.p25" }, format: { type: "percent", decimals: 1 } },
      lt_p75: { source: { json: "tiles[id=late_trip_share].typical_range.p75" }, format: { type: "percent", decimals: 1 } },
      lt_days: { source: { json: "tiles[id=late_trip_share].typical_range.days" }, format: { type: "count" } },
      late: { source: { json: "tiles[id=late_trip_share].late_trips" }, format: { type: "count" } },
      compared: { source: { json: "tiles[id=late_trip_share].trips_compared" }, format: { type: "count" } },
      pct_late_wd: { source: { json: "tiles[id=late_trip_share].value_weekday" }, format: { type: "percent", decimals: 1 } },
      avg_excess: { source: { json: "tiles[id=avg_trip_excess_seconds].value_seconds" }, format: { type: "duration" } },
      avg_excess_s: { source: { json: "tiles[id=avg_trip_excess_seconds].value" }, format: { type: "number", decimals: 1 } },
      avg_excess_wd: { source: { json: "tiles[id=avg_trip_excess_seconds].value_weekday_seconds" }, format: { type: "duration" } },
      avg_excess_wd_s: { source: { json: "tiles[id=avg_trip_excess_seconds].value_weekday" }, format: { type: "number", decimals: 1 } },
      wl_sentence: { source: { json: "tiles[id=worst_line].sentence" }, format: { type: "text" } },
      wl_verdict: { source: { json: "tiles[id=worst_line]" }, format: { type: "worst_line_verdict" } },
      wl_rule: { source: { json: "tiles[id=worst_line].tie_rule" }, format: { type: "text" } },
      wl_a: { source: { json: "tiles[id=worst_line].display" }, format: { type: "text" } },
      wl_b: { source: { json: "tiles[id=worst_line].runner_up_display" }, format: { type: "text" } },
      wl_a_id: { source: { json: "tiles[id=worst_line].value" }, format: { type: "text" } },
      wl_b_id: { source: { json: "tiles[id=worst_line].runner_up_value" }, format: { type: "text" } },
      a_pct: { source: { json: "tiles[id=worst_line].metric_value_exact" }, format: { type: "percent", decimals: 1 } },
      b_pct: { source: { json: "tiles[id=worst_line].runner_up_metric_value_exact" }, format: { type: "percent", decimals: 1 } },
      late_threshold: LATE,
    },
    day: {
      // line_day_metrics (Red, late_trip_share): the day's late_trips / trips_compared, and the typical
      // value = median of the same measure over the prior 28 days of the same day type (typical_*).
      answer: "{day_label_sentence}, {late_trips} of {trips_compared} Red Line trips were more than {late_threshold} late ({pct}%).",
      means: "A typical {cmp_daytype_one} is {cmp_pct}% (the median of the {cmp_days} {cmp_daytype} before, {cmp_window}).",
      chips: [{ text: "Measured · train runs" }],
      visual: { type: "dots", token: "pct", dots: 5, color: "line:Red", caption: "of trips late" },
      tokens: {
        late_trips: { source: { query: `select numerator as v from {lineDayMetrics} where ${LDM("Red", "late_trip_share")}` }, format: { type: "count" } },
        trips_compared: { source: { query: `select denominator as v from {lineDayMetrics} where ${LDM("Red", "late_trip_share")}` }, format: { type: "count" } },
        pct: { source: { query: `select value as v from {lineDayMetrics} where ${LDM("Red", "late_trip_share")}` }, format: { type: "percent", decimals: 1 } },
        late_threshold: LATE,
        cmp_pct: { source: { query: `select typical_median as v from {lineDayMetrics} where ${LDM("Red", "late_trip_share")}` }, format: { type: "percent", decimals: 1 } },
        cmp_days: { source: { query: `select typical_days::double as v from {lineDayMetrics} where ${LDM("Red", "late_trip_share")}` }, format: { type: "count" } },
        cmp_daytype: { source: { query: `select day_type as v from {lineDayMetrics} where ${LDM("Red", "late_trip_share")}` }, format: { type: "daytype_plural" } },
        cmp_daytype_one: { source: { query: `select day_type as v from {lineDayMetrics} where ${LDM("Red", "late_trip_share")}` }, format: { type: "daytype_one" } },
        cmp_window: { source: { query: `select typical_first_date::varchar || '|' || typical_last_date::varchar as v from {lineDayMetrics} where ${LDM("Red", "late_trip_share")}` }, format: { type: "date_range" } },
      },
    },
  },
  {
    id: "even_gaps",
    caption: "Plate IV. Gaps between trains, and the riders waiting at the gate.",
    question: "Are headways kept?",
    answer: "{pct_long_gap}% of departures, about {long_gap_ratio}, came more than {gap_ratio}× the scheduled headway after the train before.",
    means: "On weekdays, {pct_entries_in_gaps}% of gate entries happen during those gaps (gate entries {rider_first} to {rider_last}; train data {train_first} to {train_last}).",
    chips: [{ text: "Measured · train runs", basis: "all days", at: "answer" }, { text: "Estimate · gate entries", basis: "weekdays", at: "means", through: "gated_entries" }],
    visual: { type: "dots", token: "pct_long_gap", dots: 10, caption: "of departures after a long gap" },
    focus: { stations: { json: "worst_stations[*].station_id" }, note: "Map: stations where the most gate entries meet a long gap" },
    tokens: {
      pct_long_gap: { source: { json: "tiles[id=long_gap_share].value" }, format: { type: "percent", decimals: 1 } },
      long_gap_ratio: { derive: { from: "pct_long_gap", as: "one_in_n" } },
      gap_ratio: GAP_RATIO,
      rider_first: { source: { json: "meta.rider_basis_window.first" }, format: { type: "day_short" } },
      rider_last: { source: { json: "meta.data_through.gated_entries" }, format: { type: "day_short" } },
      train_first: { source: { json: "meta.service_date_window.first" }, format: { type: "day_short" } },
      train_last: { source: { json: "meta.data_through.subway" }, format: { type: "day_short" } },
      pct_entries_in_gaps: { source: { json: "tiles[id=weekday_entries_in_long_gaps].share_of_entries" }, format: { type: "percent", decimals: 1 } },
    },
    day: {
      answer: "{day_label_sentence}, {d_gaps} of {d_obs} departures came more than {gap_ratio}× the scheduled headway after the train before ({d_pct}%).",
      means: null,
      chips: [{ text: "Measured · train runs", at: "answer" }],
      visual: { type: "dots", token: "d_pct", dots: 10, caption: "of departures after a long gap" },
      tokens: {
        d_gaps: { source: { query: `select sum(long_gaps)::double as v from {lineDaily} where ${ALL_DAY}` }, format: { type: "count" } },
        d_obs: { source: { query: `select sum(headway_observations)::double as v from {lineDaily} where ${ALL_DAY}` }, format: { type: "count" } },
        d_pct: { source: { query: `select sum(long_gaps)::double / nullif(sum(headway_observations), 0) as v from {lineDaily} where ${ALL_DAY}` }, format: { type: "percent", decimals: 1 } },
        gap_ratio: GAP_RATIO,
      },
    },
  },
  {
    id: "extra_time",
    caption: "Plate V. The cushion a Green Line rider has to leave.",
    question: "How much extra time should I leave?",
    answer: "The 90th-percentile run takes {green_buffer}% longer than the median, averaged over Green Line stretches ({traversals} runs{green_window})",
    means: "Plan for the worst 1 in 10: add {green_buffer}% to that stretch's usual time.",
    chips: [{ text: "Measured · train runs" }],
    visual: {
      type: "bars", color: "line:Green",
      bars: [{ label: "Usual", token: "green_typ" }, { label: "Worst 1 in 10", token: "green_p90" }],
    },
    focus: { lines: ["Green"], note: "Map: Green Line" },
    tokens: {
      green_buffer: { source: { table: "lineBuffer", column: "buffer_index", where: { line_id: "Green" } }, format: { type: "percent", decimals: 0 } },
      traversals: { source: { table: "lineBuffer", column: "traversals", where: { line_id: "Green" } }, format: { type: "count" } },
      // dbt: first/last_service_date on line_buffer; missing -> window left out, no error.
      green_window: { source: { query: "select first_service_date::varchar || '|' || last_service_date::varchar as v from {lineBuffer} where line_id = 'Green'" }, format: { type: "date_range_to" }, optional: true, prefix: ", " },
      green_typ: { source: { table: "lineBuffer", column: "avg_segment_median_run_seconds", where: { line_id: "Green" } }, format: { type: "duration" } },
      green_p90: { source: { table: "lineBuffer", column: "avg_segment_p90_run_seconds", where: { line_id: "Green" } }, format: { type: "duration" } },
    },
  },
  {
    id: "worst_spot",
    caption: "Plate VI. One stretch: Ashmont to Shawmut.",
    question: "Can the worst spot look fine on average?",
    answer: "{ash_name} usually takes {ash_typ} against a {ash_sched} schedule, but 1 in 10 runs takes {ash_p90} or more.",
    // Terminal split: the platform wait, never called "late".
    // the dbt build 23d4086: terminal hold spread + worst 14-day window (segments worst_window_*). No cause stated.
    means: "Trains wait at {ash_from} before leaving: {ash_hold_med} on a typical run (median), {ash_hold} on average, and {ash_hold_p90} or more on 1 in 10. That's a recorded wait on the platform, not late running. {ash_win} held {ash_win_delay}% of this stretch's delay in {ash_win_runs}% of its runs.",
    // Superseded (never shown): "Trains wait there at the end of the line, which points to dispatching, not track."
    chips: [{ text: "Measured · train runs" }],
    visual: {
      type: "bars", color: "line:Red",
      bars: [{ label: "Usual", token: "ash_typ" }, { label: "Worst 1 in 10", token: "ash_p90" }],
      marker: { label: "Schedule", token: "ash_sched" },
    },
    focus: { segments: { query: `select segment_id as v from {segments} where ${ASHMONT_SHAWMUT}` }, note: "Map: Ashmont to Shawmut" },
    tokens: {
      ash_name: { source: ash("segment_name"), format: { type: "text" } },
      ash_from: { source: ash("from_station_name"), format: { type: "text" } },
      ash_typ: { source: ash("median_run_seconds"), format: { type: "duration" } },
      ash_sched: { source: ash("median_scheduled_run_seconds"), format: { type: "duration" } },
      ash_p90: { source: ash("p90_run_seconds"), format: { type: "duration" } },
      ash_hold: { source: ash("terminal_hold_mean_seconds"), format: { type: "duration" } },
      ash_hold_med: { source: ash("terminal_hold_median_seconds"), format: { type: "duration" } },
      ash_hold_p90: { source: ash("terminal_hold_p90_seconds"), format: { type: "duration" } },
      ash_win: { source: ash("worst_window_start_date::varchar || '|' || worst_window_end_date::varchar"), format: { type: "date_range" } },
      ash_win_delay: { source: ash("worst_window_share_of_delay"), format: { type: "percent", decimals: 1 } },
      ash_win_runs: { source: ash("worst_window_share_of_runs"), format: { type: "percent", decimals: 1 } },
    },
  },
  {
    id: "fix_first",
    caption: "Plate VII. The ten stretches losing the most recorded time, as sealed on the map.",
    question: "Stretches losing the most recorded time",
    answer: null,
    means: null,
    chips: [{ text: "Measured · train runs", basis: "weekdays" }],
    // Same ranking as the map's numbered top 10 (STRETCH_METRIC).
    visual: { type: "top10", metric: "train_delay", footer: "{share}% of all stretch train delay" },
    focus: { segments: "top10", note: "Map: the 10 stretches in this list" },
    tokens: {},
  },
]);

// ---------------------------------------------------------------- charts (Charts panel)
// Each chart names its table (a TABLES key, or `file` = a Parquet base name next to board_data.json
// that the board registers on load) and the columns it reads. A missing table or column shows
// CHART_WAITING; nothing is estimated. Filter-driven charts follow the shared filters listed in
// `filters`; the survey and Commuter Rail never do and carry their own dates.
export const CHART_WAITING = "Waiting for the checked data";
export const CHARTS = Object.freeze({
  // Bound now: share of runs more than the late threshold late, per line and service date.
  daily: {
    title: "Late trips by day",
    table: "lineDaily",
    columns: { date: "service_date", line: "line_id", dayType: "day_type", late: "late_trips", compared: "trips_compared" },
    threshold: "meta.thresholds.late_trip_seconds",
    filters: ["dates", "dayType", "lines", "dow"],
  },
  // Hour x day of week is the dbt build's table (set hourly.file + columns). Until it lands the heatmap uses
  // time-of-day period x day of week from station_daily (exact sums of long gaps / departures).
  heatmap: {
    title: "When long gaps happen",
    hourly: { file: null, columns: { date: "service_date", hour: "hour", line: "line_id", station: "station_id", dayType: "day_type", num: "long_gaps", den: "headway_observations" } },
    table: "stationDaily",
    columns: { date: "service_date", period: "service_period_id", line: "line_id", station: "station_id", dayType: "day_type", num: "long_gaps", den: "headway_observations" },
    threshold: "meta.thresholds.long_gap_ratio",
    filters: ["dates", "dayType", "lines", "station"],
  },
  // dbt: 1-minute lateness bins per line and service date.
  histogram: {
    title: "How late runs are, minute by minute",
    file: null,
    columns: { date: "service_date", line: "line_id", dayType: "day_type", bin: "late_minute", runs: "runs" },
    threshold: "meta.thresholds.late_trip_seconds",
    filters: ["dates", "dayType", "lines", "dow"],
  },
  // dbt: train delay per line and service date. Drawn only when the slices add up to the
  // system total (CHARTS.donut.total) within rounding; otherwise an error state.
  donut: {
    title: "Each line's share of train delay",
    file: null,
    columns: { date: "service_date", line: "line_id", dayType: "day_type", delay: "train_delay_seconds" },
    total: { table: "trainDelayDaily", date: "service_date", dayType: "day_type", delay: "train_delay_seconds" },
    tolerance: 0.5,              // seconds per day summed: "within rounding"
    filters: ["dates", "dayType", "dow"],
  },
  // dbt: 2025 MBTA System-Wide Passenger Survey by line. Not filter-driven; own field dates.
  survey: {
    title: "2025 MBTA passenger survey",
    file: null,
    columns: { line: "line_id", topic: "topic", category: "category", share: "share", moe: "margin_of_error", n: "sample_size",
      fieldStart: "field_start_date", fieldEnd: "field_end_date" },
    topics: [["income", "Household income"], ["race_ethnicity", "Race and ethnicity"], ["trip_purpose", "Trip purpose"],
      ["fare_type", "Fare type"], ["car_access", "Car access"]],
    note: "Who rides each line, from the survey. It describes riders; it doesn't explain delays.",
  },
});

// ---------------------------------------------------------------- Freedom Trail (the dbt build's table)
// out/freedom_trail.parquet: 16 sites in official order, each with its nearest T stop. Off by default;
// waiting state until the file is listed in board_data.json. Never mixed into delay figures.
// Distances are straight-line (never walking distance); the walk time is an estimate.
export const FREEDOM_TRAIL = Object.freeze({
  file: "freedom_trail",
  columns: {
    order: "site_order", name: "site_name", lat: "latitude", lon: "longitude",
    stopId: "nearest_stop_id", stopName: "nearest_stop_name", stopLines: "nearest_stop_line_ids",
    distanceLabel: "distance_label", walkSeconds: "est_walk_seconds", walkBasis: "walk_basis",
    source: "source_url", note: "note",
  },
  pathLabel: "order of sites, not the walking route",
  waiting: "Freedom Trail sites appear once the checked table lands.",
});

// ---------------------------------------------------------------- opening statement (scroll page)
// The latest service day's headline, system-wide (line_daily summed over routes; train_delay_daily).
// Same token rules as the cards: anything missing shows `waiting`, never an estimate.
// Latest service day, from line_day_metrics (scope "system" = all subway lines, and per line); the
// typical value is the dbt build's typical_median (median of the prior 28 days of the same day type).
// From board_data.json latest_day (the same rows as line_day_metrics), so the statement shows before DuckDB loads.
const LD = (scope, measure, col) => `latest_day.scopes[scope_id=${scope}].measures.${measure}.${col}`;
const sysTok = (scope, measure, col, format) => col.includes(" ") || col.includes(":")
  ? { source: { query: `select ${col} as v from {lineDayMetrics} where ${LDM(scope, measure)}` }, format }
  : { source: { json: LD(scope, measure, col) }, format };
const P1 = { type: "percent", decimals: 1 }, S1 = { type: "number", decimals: 1 }, CNT = { type: "count" };
export const STATEMENT = Object.freeze({
  // Lead (the dbt build, 23d4086): share of trips more than the late threshold late (Lantern's own measure, not an
  // MBTA metric), all days; then train delay per run between stops as the "where" figure.
  answer: "Over the last {win_days} days, {all_pct}% of subway trips ({all_late} of {all_compared}) ran more than {late_threshold} late; on a typical day it runs {all_p25}% to {all_p75}%. Between stops, each train run took {td_per_run} longer than scheduled on an average weekday, late time only.",
  // Lead "%DATE%" and "%THR%" are filled in app.js from state.serviceDate and meta.thresholds.late_trip_seconds.
  means: "%DATE%: {sys_late} of {sys_compared} train runs were %THR%+ min over scheduled run time ({sys_pct}%); typical {sys_daytype} range {sys_p25}% to {sys_p75}%.",
  // Latest day with a thin typical (dbt: typical_is_thin, fewer than 3 comparable days): no typical values.
  meansThin: "%DATE%: {sys_late} of {sys_compared} train runs were %THR%+ min over scheduled run time ({sys_pct}%); not enough comparable days ({thin_n}) for a typical {sys_daytype}.",
  thinJson: "latest_day.scopes[scope_id=system].measures.late_trip_share.typical_is_thin",
  thinTokens: { thin_n: { source: { json: "latest_day.scopes[scope_id=system].measures.late_trip_share.typical_days_n" }, format: { type: "count" } } },
  waiting: "Waiting for the checked figures.",
  chips: [{ text: "Measured · train runs" }],
  tokens: {
    win_days: { source: { json: "meta.service_date_window.days" }, format: { type: "count" } },
    all_pct: { source: { json: "tiles[id=late_trip_share].value" }, format: { type: "percent", decimals: 1 } },
    all_p25: { source: { json: "tiles[id=late_trip_share].typical_range.p25" }, format: { type: "percent", decimals: 1 } },
    all_p75: { source: { json: "tiles[id=late_trip_share].typical_range.p75" }, format: { type: "percent", decimals: 1 } },
    all_late: { source: { json: "tiles[id=late_trip_share].late_trips" }, format: { type: "count" } },
    all_compared: { source: { json: "tiles[id=late_trip_share].trips_compared" }, format: { type: "count" } },
    td_per_run: { source: { json: "tiles[id=train_delay_weekday].per_run_seconds" }, format: { type: "duration" } },
    sys_late: sysTok("system", "late_trip_share", "numerator", CNT),
    sys_compared: sysTok("system", "late_trip_share", "denominator", CNT),
    sys_pct: sysTok("system", "late_trip_share", "value", P1),
    sys_typ: sysTok("system", "late_trip_share", "typical_median", P1),
    sys_p25: sysTok("system", "late_trip_share", "typical_p25", P1),
    sys_p75: sysTok("system", "late_trip_share", "typical_p75", P1),
    sys_daytype: { source: { json: "latest_day.day_type" }, format: { type: "daytype_one" } },
    typ_days: sysTok("system", "late_trip_share", "typical_days", CNT),
    typ_first: sysTok("system", "late_trip_share", "typical_first_date", { type: "text" }),
    typ_last: sysTok("system", "late_trip_share", "typical_last_date", { type: "text" }),
    late_threshold: { source: { json: "meta.thresholds.late_trip_seconds" }, format: { type: "duration" } },
    d_per_run_s: sysTok("system", "train_delay_positive_per_run_seconds", "value", S1),
    d_typ_s: sysTok("system", "train_delay_positive_per_run_seconds", "typical_median", S1),
    b_late: sysTok("Blue", "late_trip_share", "value", P1),
    b_late_typ: sysTok("Blue", "late_trip_share", "typical_median", P1),
    b_gap: sysTok("Blue", "long_gap_share", "value", P1),
    b_gap_typ: sysTok("Blue", "long_gap_share", "typical_median", P1),
    r_late: sysTok("Red", "late_trip_share", "value", P1),
    r_late_typ: sysTok("Red", "late_trip_share", "typical_median", P1),
  },
});
