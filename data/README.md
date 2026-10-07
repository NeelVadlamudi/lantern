# Data sources

All inputs are public MBTA files. Nothing here needs an account or an API key.
`scripts/load_raw.py` downloads them into `data/raw/` (gitignored) and lands them unchanged in
the `raw` schema of the DuckDB file. All cleaning happens in dbt.

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

| Source | URL | What it gives | Raw table | Rows loaded |
|---|---|---|---|---|
| LAMP subway on-time performance, one Parquet file per service date | https://performancedata.mbta.com/lamp/subway-on-time-performance-v1/index.csv | Every subway train arrival at every stop: actual and scheduled run times, actual and scheduled headways | `raw.lamp_subway_on_time` | 3,641,449 (90 service dates) |
| LAMP GTFS archive, 2026 (`stops`, `routes`, `route_patterns`, `stop_times`, `trips`, `shapes`) | https://performancedata.mbta.com/lamp/gtfs_archive/2026/ | Stations and coordinates, route colors, canonical stop order, track shapes. Each record carries the date range of the GTFS version it came from | `raw.gtfs_*` | stops 11,955; routes 5,296; route_patterns 34,465; stop_times 3,724; trips 655; shapes 22,032 |
| Gated Station Entries (item `001c177f07594e7c99f193dde32284c9`) | https://mbta-massdot.opendata.arcgis.com/datasets/001c177f07594e7c99f193dde32284c9 | Fare-gate entries per station, line and 30-minute bin | `raw.mbta_gated_station_entries` | 1,257,500 |
| Monthly Ridership by Mode and Line (item `2048258a18354256a650d41f8fe4532c`) | https://mbta-massdot.opendata.arcgis.com/datasets/2048258a18354256a650d41f8fe4532c | Average weekday ridership by line and month | `raw.mbta_monthly_ridership` | 5,020 |

Notes:

- `stop_times`, `trips` and `shapes` are cut down by the loader to the representative trip of
  each subway route pattern. That is all the models need, and it keeps the warehouse small
  (the full 2026 `stop_times` file is about 80 MB).
- LAMP republishes recent service dates. The loader replaces a whole date on each load, and the
  incremental fact table reprocesses the last 3 dates on every run.
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

`data/sample/` (about 4.6 MB, committed) holds two real LAMP service dates (2026-08-27 and
2026-08-28), the subway-only slice of the 2026 GTFS archive files listed above, and gated entries
for 2026-07-01 to 2026-08-28. CI loads day one, builds, loads day two and builds again to check the
incremental model. Rebuild it with `python scripts/make_sample.py --dates 2026-08-27 2026-08-28`.
