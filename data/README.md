# Data sources

All inputs are public MBTA files. Nothing here needs an account or an API key.
DuckDB reads them in place over HTTPS (httpfs); each dbt source in
`models/staging/_sources.yml` is the read expression for one file. There is no copy step and no
raw schema. All cleaning happens in dbt.

Last full pull: 2026-10-07, 6:56 PM ET (22:56 UTC). LAMP service dates 2026-07-09 to 2026-10-06.

## Terms

- **LAMP files and the GTFS archive** (performancedata.mbta.com) are published by MassDOT/MBTA
  under the [MassDOT Developers License Agreement](https://cdn.mbta.com/sites/default/files/2023-08/mbta-massdot-develop-license-agreement.pdf).
  It allows use and redistribution of the data with attribution to MassDOT, and does not allow
  use of MBTA or MassDOT logos or any suggestion of endorsement. The board and this repo credit
  MassDOT/MBTA and state that they are not affiliated with the MBTA.
- **MBTA Open Data Portal items** (mbta-massdot.opendata.arcgis.com) used here are listed with a
  CC0 license on their item pages.
- The repository's code is MIT licensed (see `LICENSE`). That license does not cover the data;
  the data stays under the terms above.

## Used

| Source | URL | What it gives | Staging model | Rows staged |
|---|---|---|---|---|
| LAMP subway on-time performance, one Parquet file per service date | https://performancedata.mbta.com/lamp/subway-on-time-performance-v1/index.csv | Every subway train arrival at every stop: actual and scheduled run times, actual and scheduled headways | `stg_lamp__subway_trip_stops` (files listed in `index.csv`) | 3,641,449 (90 service dates) |
| LAMP GTFS archive, 2026 (`stops`, `routes`, `route_patterns`, `stop_times`, `trips`, `shapes`) | https://performancedata.mbta.com/lamp/gtfs_archive/2026/ | Stations and coordinates, route colors, canonical stop order, track shapes. Each record carries the date range of the GTFS version it came from | `stg_gtfs__*` | stops 11,955; routes 5,296; route_patterns 34,465; stop_times 3,724; trips 655; shapes 22,032 |
| Gated Station Entries (item `001c177f07594e7c99f193dde32284c9`) | https://mbta-massdot.opendata.arcgis.com/datasets/001c177f07594e7c99f193dde32284c9 | Fare-gate entries per station, line and 30-minute bin | `stg_mbta__gated_entries` | 1,257,500 |
| Monthly Ridership by Mode and Line (item `2048258a18354256a650d41f8fe4532c`) | https://mbta-massdot.opendata.arcgis.com/datasets/2048258a18354256a650d41f8fe4532c | Average weekday ridership by line and month | `stg_mbta__monthly_ridership` | 5,020 |

Notes:

- `stg_gtfs__stop_times`, `stg_gtfs__trips` and `stg_gtfs__shapes` keep only the representative
  trip of each subway route pattern (and its shape). That is all the models need, and it keeps
  the warehouse small (the full 2026 `stop_times` file is about 80 MB). This filter needs
  `stg_gtfs__route_patterns`, so these three staging models join to another staging model; it is
  the one exception to the no-joins-in-staging rule.
- The GTFS and Open Data staging models are tables kept between builds: the remote files are
  read on the first build, on `--full-refresh` or with `--vars '{refresh_reference: true}'`
  (once a day in the daily workflow), not on every build.
- LAMP republishes recent service dates. The LAMP staging table re-reads the files for the last
  4 loaded dates (latest minus `incremental_lookback_days`) and replaces those dates on every
  run, and the incremental fact reprocesses the same dates.
- Gated entries currently run through 2026-08-31, so rider weights come from July and August.
- Monthly ridership is staged and tested but not used by any mart yet.

## Not used

- **Stop Orders** and **Station-to-station Distances** (Open Data Portal): last updated before
  the Green Line Extension opened, so Union Square and the Medford branch are missing. Stop order
  comes from GTFS canonical route patterns instead, and distances are computed from coordinates
  only for a sanity test.
- **Service Alerts** history: useful for explaining delays, but it is free text with its own
  stop and route coding. Left out of this first pass.

## Sample for CI

`data/sample/` (about 4.4 MB, committed) holds two real LAMP service dates (2026-08-27 and
2026-08-28) with an `index.csv` that lists them by relative path, the subway-only slice of the
2026 GTFS archive files listed above, and gated entries for 2026-07-01 to 2026-08-28.
`--vars '{use_sample: true}'` points every source at it. CI builds day one
(`lamp_end_date: 2026-08-27`), then day two incrementally (`lamp_end_date: 2026-08-28`) with the
incremental tests on. The sample files are fixed copies; refreshing them means replacing the
files by hand (same names and columns).
