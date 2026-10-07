# Where the MBTA subway falls behind its schedule

A dbt project on public MBTA data. It compares every subway train's actual stop-to-stop run
times and gaps between trains against the published schedule, and weights the results by
fare-gate entries to show where it affects the most riders.

Public MBTA data. Live positions from the MBTA V3 API. Not affiliated with the MBTA.

Stack: dbt Core 1.12 + dbt-duckdb, with DuckDB as the warehouse. The whole pipeline is dbt:
DuckDB reads the MBTA files in place over HTTP (httpfs), dbt builds and tests the models,
writes the Parquet exports and, in an on-run-end hook, `out/board_data.json`. There are no
scripts outside dbt. Everything is open source; no accounts, keys or paid services are needed.

## The question

Which lines, stations and times of day run furthest behind schedule or leave the longest gaps
between trains, and how many riders does that touch? And is the data current?

Measures (all from `fct_trips` and `fct_trip_stop_events`; lines and the whole system use the
same grain):

- **Excess per trip**: for one train run, the sum of (actual minus scheduled) arrival-to-arrival
  time over its compared stop-to-stop segments. Averages are per train run, not per stop.
- **Late trip**: a train run whose excess per trip is more than 5 minutes. The same rule on every
  line, so long lines are more exposed to it.
- **Excess vs schedule**: total excess divided by total scheduled run time. Use this to compare
  lines of different length.
- **Long gap**: a train leaves a station more than 1.5x the scheduled gap after the previous train
  on the same line. Under 0.5x is **bunched**. Counted per departure.
- **Entries during long gaps**: for each station, line and service period, average weekday
  fare-gate entries times the long-gap share for that cell, summed. MBTA's gated-entry data
  splits each entry at transfer stations across lines (fractional counts), so nothing is counted
  twice. It is an estimate of entries, not a count of people who waited.
- **Freshness**: latest service date loaded vs. today.

The late-trip, excess and long-gap headline numbers are over **all days** (weekdays, Saturdays,
Sundays and holidays). Each of those tiles also carries the weekday-only value as a separate
field (`value_weekday`) for the board's day toggle. The entries-during-long-gaps number is
weekdays only. Day types come from `dim_dates`; holidays are a seed and are listed in
`board_data.json` under `meta.holidays`.

Thresholds are dbt vars (`late_trip_seconds`, `long_gap_ratio`, `bunched_ratio`).

## Lineage

```mermaid
flowchart LR
  subgraph sources[sources: public files read in place by DuckDB]
    lamp[(LAMP subway on-time)]
    gtfs[(GTFS archive)]
    gse[(Gated station entries)]
    mr[(Monthly ridership)]
  end
  subgraph staging
    stg_lamp[stg_lamp__subway_trip_stops]
    stg_gtfs[stg_gtfs__stops / routes / route_patterns / stop_times / trips / shapes]
    stg_gse[stg_mbta__gated_entries]
    stg_mr[stg_mbta__monthly_ridership]
  end
  subgraph intermediate
    int_perf[int_trip_stops__performance]
    int_sp[int_service_periods]
    int_seq[int_line_stop_sequence]
    int_shp[int_line_shapes]
    int_rid[int_station_period_riders]
    int_st[int_gtfs_stations_as_of]
  end
  subgraph marts
    dims[dim_dates / dim_routes / dim_stations / dim_service_periods]
    fct[fct_trip_stop_events<br/>incremental]
    fct_t[fct_trips]
    agg[mart_line_daily / mart_period / mart_station / mart_station_daily / mart_station_overview]
    geo[mart_line_stop_sequence / mart_line_shapes]
  end
  snap[[snap_gtfs_stations<br/>SCD2]]
  exports[board_* Parquet in out/]
  payload[board_tiles / board_line_totals / board_payload<br/>on-run-end: out/board_data.json]
  board{{reliability board}}
  seeds[/seeds: service periods, holidays, branches, display names/]

  lamp --> stg_lamp --> int_perf
  gtfs --> stg_gtfs
  stg_gtfs --> int_seq & int_shp & int_st & dims
  gse --> stg_gse --> int_rid
  mr --> stg_mr
  seeds --> int_sp & int_seq & dims
  int_sp --> int_perf & int_rid
  int_perf --> fct --> fct_t
  fct --> agg
  int_rid --> agg
  int_seq --> geo
  int_shp --> geo
  int_st --> snap
  dims --> agg
  agg & geo & dims --> exports --> board
  agg & geo & dims & exports --> payload --> board
```

The full graph, with column docs, is in the dbt docs site (`docs/dbt/index.html`).

## Layers

| Layer | Models | Materialization |
|---|---|---|
| Staging | 9 models, one per source table: rename, cast, dedupe, parse dates. They read the remote files directly (see Loading) | LAMP: incremental; GTFS and Open Data: tables kept between builds (see Loading) |
| Intermediate | `int_trip_stops__performance` (run times, headways, flags per arrival), `int_service_periods` (minute of day to MBTA service period), `int_line_stop_sequence`, `int_line_shapes`, `int_station_period_riders`, `int_gtfs_stations_as_of` | view, access protected |
| Marts | `dim_dates`, `dim_routes`, `dim_stations`, `dim_service_periods`, `fct_trip_stop_events`, `fct_trips`, `mart_line_daily_reliability`, `mart_period_reliability`, `mart_station_reliability`, `mart_station_daily_reliability`, `mart_station_overview`, `mart_line_stop_sequence`, `mart_line_shapes`, `mart_data_coverage` | table (fact incremental), access public, contracts enforced |
| Exports | 9 `board_*` models written to `out/*.parquet` (zstd) for the board; `board_tiles`, `board_line_totals` and `board_payload` hold the JSON for `out/board_data.json` | external (Parquet); the three JSON models are tables |

Star schema: `fct_trip_stop_events` (one row per service date, trip, route, vehicle and stop) and
`fct_trips` (one row per train run) join to `dim_dates`, `dim_routes`, `dim_stations` and
`dim_service_periods`. Every model description starts with its grain. Surrogate keys come from
`dbt_utils.generate_surrogate_key`.

Service periods follow the MBTA Service Delivery Policy (Sunrise, Early AM, AM Peak, Midday Base,
Midday School, PM Peak, Evening, Late Evening, Night), stored as a seed.

Conventions are in [CONVENTIONS.md](CONVENTIONS.md).

## Loading

There is no separate load step. Each source in `models/staging/_sources.yml` has an
`external_location`, so `{{ source() }}` renders to a DuckDB read of the public file
(`read_parquet` / `read_csv` over HTTPS, via the httpfs extension set in `profiles.yml`).

- **LAMP** (`stg_lamp__subway_trip_stops`, incremental on `service_date`): the macro
  `lamp_files_to_load()` (`macros/lamp_files.sql`) queries the LAMP `index.csv` with
  `run_query` and builds the list of Parquet URLs to read. On an incremental run that is every
  date from the latest loaded date minus `incremental_lookback_days` (3, so 4 dates are re-read,
  because LAMP republishes recent files) up to yesterday in Boston. On a first build or
  `--full-refresh` it is `lamp_start_date` to `lamp_end_date` if set, otherwise the last
  `lamp_window_days` (90) complete service dates.
- **GTFS archive** (one Parquet file per year and GTFS file) and the **Open Data** CSVs
  (gated entries, monthly ridership) are too large to download on every build (about 80 MB for
  `stop_times` alone). Their staging models are tables that keep their rows between builds: the
  remote file is read on the first build, on `--full-refresh`, or with
  `--vars '{refresh_reference: true}'` (the daily workflow sets it once a day). Otherwise the
  model inserts nothing and the existing rows stay. GTFS years come from `gtfs_years`
  (default `[2026]`); `assert_gtfs_covers_lamp_window` fails if the LAMP window needs a year that
  is not listed.
- **Sample**: `--vars '{use_sample: true}'` points every source at the small copies committed in
  `data/sample/` (two real LAMP service dates, 2026-08-27 and 2026-08-28, with a matching
  `index.csv`, subway-only GTFS subsets and gzipped Open Data CSVs). CI uses it.
- Any location can be overridden with a var (`lamp_index_url`, `gtfs_archive_url`,
  `gated_entries_url`, `monthly_ridership_url`), for example to build from a local mirror.

## Tests and contracts

288 data tests on the full build: 279 pass, 9 warn, 0 fail (plus 3 incremental checks and 1
post-build check that run only when their var is set, see below).

- Generic: `unique`, `not_null`, `relationships`, `accepted_values`,
  `dbt_utils.unique_combination_of_columns`, `dbt_utils.accepted_range`.
- Custom generic (`macros/generic_tests/`): `is_share` (0 to 1), `has_prefix` (station ids
  start with `place-`), `contiguous_sequence` (stop order 1..n with no gaps).
- Singular (`tests/`): line-daily totals reconcile to the fact table, no missing service dates,
  every observed station is on the network, adjacent stops are under 6 km apart, service periods
  cover all 1,440 minutes exactly once, every map station has coordinates, board route ids match
  the MBTA V3 API, and more.
- Board numbers (`tests/kpi/`): each headline tile, its weekday value, and each line's late
  share and excess per trip are recomputed from `fct_trips` / `fct_trip_stop_events` (not from
  the marts) and compared to the export models, failing beyond rounding (1e-4 for shares,
  0.06 s for seconds, 1 entry or 0.1% for the rider tile). Also: coverage counts match the fact,
  ungated stations have no rider rows, every map branch has its stops in order and a track shape
  inside Greater Boston, and every Parquet file listed in `board_data.json` has its model's row
  count.
- Build result: the on-run-end hook stores every node's result in `audit.build_results`, and
  writes `out/board_data.json` only if no model or test errored or failed (otherwise the previous
  file stays). `tests/assert_build_has_no_failures.sql` reads that table; a test cannot see the
  invocation it runs in, so it runs right after the build:
  `dbt test --select assert_build_has_no_failures --vars '{check_build: true}'`. The exit code of
  `dbt build` is the other half of that check.
- All 14 public marts have enforced contracts (column names and data types checked at build time).

### Data quality findings (severity warn)

These come from the source data. They are kept as warnings so they show up in every run.

| Test | Rows | What it means |
|---|---|---|
| `accepted_range` on scheduled trunk headway (staging and fact) | 81,276 | LAMP gives a scheduled headway of 0 seconds; these arrivals are left out of gap ratios |
| `accepted_range` on scheduled run seconds (fact) | 4,616 | Segments whose scheduled run time is zero or negative; left out of excess-time comparisons |
| `assert_scheduled_run_not_negative` | 3,733 | Scheduled run time between consecutive stops is negative in LAMP |
| `assert_trip_ids_not_reused_across_routes` | 3,539 | The same trip id appears at the same stop on more than one route on a date (1,316 also on two vehicles, 837 involve added trips). Route and vehicle are part of the fact grain, so the rows are kept |
| `assert_travel_outliers` | 3,266 | Stop-to-stop excess over 30 minutes (disruptions, shuttles, data gaps); kept in counts, flagged in the fact |
| `assert_gtfs_validity_ranges` | 174 | GTFS archive records whose end date is before their start date |
| `assert_gated_entries_no_missing_dates` | 46 | Station and line combinations with missing days in gated entries |
| `not_null` on gated entries `station_id` | 12 | Longwood rows with no stop id; excluded from rider weights |

## Incremental model and freshness

`fct_trip_stop_events` is incremental (`delete+insert` on `trip_stop_event_key`). Each run
reprocesses every service date within `incremental_lookback_days` (3) of the latest date already
in the table, because LAMP republishes recent days, and adds any newer dates.

The LAMP staging table is incremental the same way (`delete+insert` on `service_date`), so a
daily build downloads only the lookback dates and the new date.

To check it, save the per-date state, build a newer date, and run the three tests in
`tests/incremental/` (a newer date was added, dates older than the lookback kept the same row
counts and `loaded_at`, and fact rows per date equal staging):

```bash
dbt build --profiles-dir . --full-refresh --vars '{lamp_end_date: 2026-10-05}'
dbt run-operation save_incremental_state --profiles-dir .      # writes audit.incremental_state
dbt build --profiles-dir . --vars '{lamp_end_date: 2026-10-06, check_incremental: true}'
```

CI runs the same sequence on every push with the two sample dates.

Run on the full window (2026-07-09 to 10-05 with a full refresh, then 2026-10-06 built
incrementally): 89 dates / 3,591,892 rows before, 90 dates / 3,641,449 rows after, 5 LAMP files
read by the incremental run (2026-10-02 to 10-05 reprocessed, plus 10-06), the other 85 dates
untouched (same row counts and load times). The outputs were identical to a full build of the
90 dates.

Source freshness on LAMP: warn after 2 days, error after 4 days, on the service date.
`dbt source freshness --profiles-dir .`

## Snapshot

`snap_gtfs_stations` is a type 2 slowly changing dimension of station attributes (name,
coordinates, municipality, wheelchair boarding), built from the GTFS archive version active on
each date. A normal `dbt build` adds the version active on the latest loaded date. To replay
history, so it starts at the first 2026 GTFS version (2026-01-01) instead of the day the project
was first run, rebuild `int_gtfs_stations_as_of` for each as-of date in order and snapshot it.
`station_snapshot_replay_dates` prints the dates (first loaded date, each date a station's
attributes changed, last loaded date); with `reset: true` it drops the snapshot first:

```bash
for d in $(dbt --quiet run-operation station_snapshot_replay_dates --args '{reset: true}' --profiles-dir .); do
  dbt build --profiles-dir . -s int_gtfs_stations_as_of snap_gtfs_stations --vars "{gtfs_as_of: '$d'}"
done
dbt run --profiles-dir . -s int_gtfs_stations_as_of      # back to the latest as-of date
```

For the current window the dates are 20260709, 20260731, 20260917 and 20261006. The daily
workflow runs this when it starts from an empty warehouse.

Real changes it picked up in 2026, all on the Green Line C branch:

- Englewood Avenue and Tappan Street: `wheelchair_boarding` changed from 2 (not accessible) to
  1 (accessible) on 2026-07-31. Englewood Avenue's coordinates also moved.
- Dean Road: coordinates moved on 2026-09-17.

128 snapshot rows for 125 stations.

## Semantic layer

`models/marts/_semantic.yml` defines two semantic models (`trip_stop_events`, `trips`) and 12
metrics, including `late_trip_share`, `long_gap_share`, `headway_adherence` and
`excess_travel_minutes`, with `dim_dates` as the time spine. It passes `dbt parse`. MetricFlow itself
(`dbt-metricflow`) is not installed, so the metrics have not been queried on DuckDB. The same
numbers are computed in the marts and checked by the tests in `tests/kpi/`.

## Exposure and board files

The board is declared as a dbt exposure (`reliability_board`, type application) that depends on
the nine `board_*` export models and `board_payload`. Exports are Parquet files in `out/` that the board queries in
the browser with DuckDB-WASM:

| File | Grain | Size |
|---|---|---|
| `line_daily.parquet` | route x service date (with `day_type`) | 39 KB |
| `line_periods.parquet` | route x day type x service period | 14 KB |
| `station_periods.parquet` | station x line x day type x service period | 83 KB |
| `station_daily.parquet` | station x line x service date x service period (additive counts, with `day_type`) | 544 KB |
| `map_stations.parquet` | station, with coordinates and map values | 10 KB |
| `line_stops.parquet` | branch x direction x stop order | 9 KB |
| `line_shapes.parquet` | branch x direction x track point | 40 KB |
| `routes.parquet` | route | 1 KB |
| `service_periods.parquet` | service period | 1 KB |

`out/board_data.json` is built in dbt too. `board_tiles` (one row per headline tile),
`board_line_totals` (one row per route) and `board_payload` (one row, one JSON column per block:
meta, tiles, lines, worst stations, worst periods, map with stations, ordered stop lists, track
shapes and period values, files, data coverage, glossary) are DuckDB tables built with
`json_object` and lists. Glossary and source text are seeds (`board_glossary`, `board_sources`).
The on-run-end hook (`macros/write_build_outputs.sql`) adds the `build` block, put together in
Jinja from the run's `results` (totals by status and by resource type, test counts, warned
tests) and the project `graph` (models by layer, contracted, incremental and external models,
lineage edges), and COPYs the row to `out/board_data.json`. It also writes
`out/build_results.json` (unique_id, resource_type, name, status, execution_time, failures,
message for every node). Both are written only when `board_payload` was built in that
invocation and nothing errored or failed, so a partial run such as `dbt build -s board_payload`
gives a build block that covers only that run.

## CI and daily refresh

- `.github/workflows/dbt_ci.yml` (push, pull request): installs the pinned requirements (dbt
  and sqlfluff), runs `sqlfluff lint`, builds the committed sample with `--full-refresh` for the
  first date, saves the incremental state, builds the second date incrementally with the
  incremental tests on, runs the post-build check, and generates docs. No calls to MBTA and no
  secrets.
- `.github/workflows/daily_refresh.yml` (daily at 11:30 UTC): restores the DuckDB file from
  `actions/cache`, runs source freshness and `dbt build --vars '{refresh_reference: true}'`
  (only new LAMP dates on a cache hit, the default 90-day window on a miss, when it also replays
  the station snapshot), runs the post-build check, saves the DuckDB file back to the cache,
  generates docs into `docs/dbt/`, and publishes `docs/` (site root) plus `out/` with
  `actions/upload-pages-artifact` and `actions/deploy-pages`. It never commits to the repository.

## How to run

Install dbt: `python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt`

```bash
dbt deps --profiles-dir .

# full data: last 90 complete service dates, read straight from MBTA (about 300 MB)
dbt build --profiles-dir .

# or a fixed window
dbt build --profiles-dir . --full-refresh --vars '{lamp_start_date: 2026-07-09, lamp_end_date: 2026-10-06}'

# or offline, from the committed sample
dbt build --profiles-dir . --full-refresh --vars '{use_sample: true}'

# daily update: new LAMP dates only; re-read GTFS and Open Data
dbt build --profiles-dir . --vars '{refresh_reference: true}'

# check the last build had no failures
dbt test --profiles-dir . --select assert_build_has_no_failures --vars '{check_build: true}'

# docs (single static file, opens from disk)
dbt docs generate --profiles-dir . --static --target-path target_docs
mkdir -p docs/dbt && cp target_docs/static_index.html docs/dbt/index.html

# lint
sqlfluff lint models tests
```

Every build writes `out/*.parquet`, `out/board_data.json` and `out/build_results.json`.
Paths can be changed with `MBTA_DUCKDB_PATH` (warehouse file) and `MBTA_OUT_DIR` (export folder).

## Findings

Window: 90 service dates, 2026-07-09 to 2026-10-06. 3,641,449 train-at-stop records,
352,266 train runs observed, 222,811 of them with at least one segment comparable to schedule.
The tests in `tests/kpi/` recompute each number below from the fact tables on every build.

| Figure | All days | Weekdays | Definition |
|---|---|---|---|
| Late trips | **11.0%** | 11.9% | Share of compared train runs (222,811 on all days) more than 5 minutes over scheduled time |
| Excess per trip | **+35.2 s** | +46.4 s | Average per train run; on all days 1.9% of an average 31-minute scheduled run (weekdays 2.4%) |
| Long gaps | **17.3%** | 17.9% | Share of departures (3,131,460 on all days) more than 1.5x the scheduled gap after the previous train |

Weekdays exclude holidays (Labor Day, 2026-09-07, is the one holiday in the window).

| Figure | Value | Definition |
|---|---|---|
| Weekday entries during long gaps | **about 50,300** | Of 302,700 average weekday gate entries at 68 gated stations (16.6%). Average over all days, weekends included: about 39,600 |
| Red Line excess per trip | **+145.5 s** | Same per-trip grain as the system figure |

Line figures below are over all days; time-of-day and station figures say weekday where they are.

- **Red Line is most often late: 20.9% of its trips are 5+ minutes over,** and it averages
  145.5 s over per trip. Part of that is length: a Red Line trip is scheduled for 38 minutes on
  average against 31 systemwide. Relative to scheduled time Red runs 6.3% over.
- **Blue Line runs furthest over its schedule relative to trip length: 8.5%** (94 s on an
  18-minute trip), but only 9.5% of its trips cross the fixed 5-minute line.
- Others, late share / excess vs schedule: Green D 15.3% / 1.0%, Green E 13.4% / -0.2%,
  Green B 9.8% / -0.3%, Green C 8.7% / -0.1%, Orange 5.6% / 1.6%, Mattapan 1.5% / -15.1%.
  Green branches average close to schedule but have a wide spread, so many trips still end up
  late.
- **The Green Line has the most uneven gaps.** Long-gap share: Green D 25.9%, Green E 23.2%,
  Green B 21.3%, Green C 20.4%, against 9.7% on Orange and 7.0% on Mattapan. Green branches also
  bunch most (13 to 16% of departures under half the scheduled gap).
- **Worst time of day: weekday Red Line PM Peak (4:00 to 6:29 PM), 33.6% of trips 5+ minutes
  late,** then Red Line Midday Base (29.1%) and Midday School (26.0%). Across all lines, weekday
  PM Peak (15.0%) and Midday Base (14.7%) are the worst periods; AM Peak is 10.3%.
- **Stations, average weekday entries during long gaps:** Park Street about 2,900 of 11,300,
  North Station 2,700 of 15,200, Government Center 2,300 of 6,400 (its departures are long gaps
  36.5% of the time, rider-weighted), South Station 2,000 of 10,800, Downtown Crossing 1,900 of
  12,600.
- **Freshness:** data runs through 2026-10-06, one day behind, which is LAMP's normal lag.

## Limits

Data coverage (`mart_data_coverage`, also in `out/board_data.json` under `coverage`):

| Route | Trip-stop events | No scheduled travel time | No scheduled headway | Neither | Events at ungated stations |
|---|---|---|---|---|---|
| Red | 612,030 | 47,900 (7.8%) | 7,775 (1.3%) | 6,636 (1.1%) | 0% |
| Mattapan | 168,949 | 23,529 (13.9%) | 1,305 (0.8%) | 185 (0.1%) | 74.7% |
| Orange | 659,500 | 39,356 (6.0%) | 1,851 (0.3%) | 112 (0.0%) | 0% |
| Green B | 438,946 | 45,626 (10.4%) | 21,911 (5.0%) | 3,762 (0.9%) | 73.1% |
| Green C | 373,473 | 43,201 (11.6%) | 21,765 (5.8%) | 3,985 (1.1%) | 65.7% |
| Green D | 523,493 | 107,840 (20.6%) | 72,589 (13.9%) | 47,731 (9.1%) | 52.2% |
| Green E | 483,579 | 58,138 (12.0%) | 22,883 (4.7%) | 2,209 (0.5%) | 33.5% |
| Blue | 381,479 | 36,348 (9.5%) | 1,936 (0.5%) | 566 (0.1%) | 0% |
| All | 3,641,449 | 401,938 (11.0%) | 152,015 (4.2%) | 65,186 (1.8%) | 31.0% |

"No scheduled travel time" means LAMP has no scheduled run time from the previous stop, or it is
zero or less; it includes the first stop of every trip and added trips. Those events are left out
of excess-time figures, and events with no scheduled headway are left out of gap figures. Green D
has the most unmatched events, mostly added trips.

57 of 125 stations have no gated-entry data and so no rider weight: 51 Green Line stations and 6
Mattapan trolley stops. Ids:
Green: place-alsgr, place-amory, place-babck, place-bckhl, place-bcnfd, place-bcnwa, place-bland,
place-bndhl, place-brico, place-brkhl, place-brmnl, place-bucen, place-buest, place-bvmnl,
place-chhil, place-chill, place-chswk, place-clmnl, place-cool, place-denrd, place-eliot,
place-engav, place-fbkst, place-fenwd, place-fenwy, place-grigg, place-harvd, place-hsmnl,
place-hwsst, place-kntst, place-lake, place-lngmd, place-longw, place-mfa, place-mispk,
place-newtn, place-newto, place-nuniv, place-rsmnl, place-rvrwy, place-smary, place-sougr,
place-sthld, place-stpul, place-sumav, place-symcl, place-tapst, place-waban, place-wascm,
place-woodl, place-wrnst.
Mattapan: place-butlr, place-capst, place-cedgr, place-cenav, place-miltt, place-valrd.

Green Line surface share: 51 of 70 Green Line stations (72.9%) and 55.1% of Green Line trip-stop
events are at stations without gated data. This counts ungated stations as surface; the two
exceptions are Symphony (underground, no gate data) and Longwood (its gated rows have no stop id).

Other limits:

- Schedule comparison is only as good as the scheduled values in LAMP. Added trips and the first
  stop of each trip have no scheduled run time or headway and are left out of the ratios (see the
  warn tests above).
- The first segment of a trip uses departure-to-arrival time, because the time a train sits at
  its origin terminal is layover, not delay.
- Rider weights use gated entries only (2026-07-07 to 2026-08-31, the latest published). 68 of 125
  stations have gated data; surface Green Line stops and Mattapan have no fare gates, so their map
  values fall back to arrival-weighted averages (`has_rider_data = false`).
- Entries during long gaps assumes entries are spread evenly across long and normal gaps within
  a station, line and service period, and credits each entry to the line MBTA assigns it to
  (a transfer from another line inside the station is not counted). Rider weights come from
  July and August; September ridership is likely higher, so it is probably an undercount.
- `trips` counts every observed train run, including about 115,000 records for added Green Line
  trips (most cover a single stop) that have no schedule to compare against. Use
  `trips_compared` as the denominator for trip shares, as the tiles do.
- Station snapshot history starts with the first 2026 GTFS archive version (2026-01-01).
- Metrics are defined and parsed but not queried with MetricFlow (see Semantic layer).
- Service alerts are not joined, so the project shows where and when, not why.

## License

Code: MIT, see [LICENSE](LICENSE). Data: MBTA/MassDOT public data under the MBTA's own terms,
not the MIT license. Sources and terms are listed in [data/README.md](data/README.md).
