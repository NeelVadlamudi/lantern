# Lantern

Shows which hours run late most often, and which stations cost riders the most time, using MBTA train event data.

[Live board](https://neelvadlamudi.github.io/lantern/) · [dbt documentation](https://neelvadlamudi.github.io/lantern/dbt/) · [Portfolio](https://neelvadlamudi.github.io/neelresume/)

## What the board shows

**11.8% of compared train runs took more than five minutes over scheduled run time** across all days in the **August 11–November 8, 2026** window. The weekday share was **12.6%**. These are the values published in [`data/board_data.json`](https://neelvadlamudi.github.io/lantern/data/board_data.json), checked November 9, 2026, under the `late_trip_share` tile. The board refreshes daily; these are a dated reading, not permanent project results.

The denominator is scheduled train runs that can be compared with recorded stop-to-stop times. Line-days with a planned service change are excluded from this tile. It measures time spent running over schedule between the first and last compared stops—not whether a train arrived late at its final destination, and not the MBTA's per-rider reliability measure.

The board helps a reader move from the system figure to a line, station, time of day or track segment worth investigating. It separates measured train delay from estimated rider time lost.

## How the data reaches the board

Public MBTA files → DuckDB staging → dbt facts and marts → Parquet and JSON → GitHub Pages.

DuckDB reads LAMP performance files, archived GTFS schedules and MBTA Open Data. dbt defines the grains, transformations, contracts and reconciliation checks. The browser reads the published JSON first and queries Parquet with DuckDB-WASM for detail. MapLibre displays the network; current train positions come separately from the MBTA V3 API.

The main fact table, `fct_trip_stop_events`, records a train at a stop on a service date. `fct_trips` rolls those observations up to train runs. `int_train_runs` and the segment marts provide the track-level view. Model and column definitions are in the [dbt documentation](https://neelvadlamudi.github.io/lantern/dbt/); naming and modeling rules are in [CONVENTIONS.md](CONVENTIONS.md).

## Decisions behind the measures

- **Compare like with like.** The late-trip tile uses matched scheduled trips and excludes planned-change line-days. Other measures can use a different basis; the exported fields carry that distinction.
- **Keep early and late time separate.** Positive excess counts late time only. Net excess lets early runs offset late ones. They answer different questions and should not be substituted for one another.
- **Separate terminal holds where the timestamps allow it.** Departure-to-arrival time is used out of terminals, with the recorded platform hold kept separately. Holding before a terminal arrival cannot be split from the run with these timestamps.
- **Do not turn missing schedules into punctual trains.** Observations without usable scheduled times are counted in coverage but left out of the affected comparisons.
- **Label rider estimates.** Fare-gate entries weight expected waiting time and the first segment after boarding. Entries are not unique riders, and ungated stops do not have the same coverage. Gate entries come from the MBTA's Gated Station Entries release, which the MBTA says is updated on a one- to two-month delay, so a gap between the two dates on the board is normal. As of November 9, 2026, the published entries run through September 30, 2026. Rider weights use the latest 56 days of gate entries (currently August 6 to September 30, 2026); the exact window is listed in `board_data.json`.

A long gap is a departure interval greater than **1.5 times** the scheduled gap. The late-trip threshold is **300 seconds**. These rules are configured in [dbt_project.yml](dbt_project.yml) and published in `meta.thresholds`, rather than hidden in chart code.

## Checks and operation

The sample CI workflow runs SQL linting, a full sample build, an incremental build and post-build checks. Tests recompute headline measures from the facts, reconcile totals across grains, check model contracts and verify exports. See [tests/](tests/) and [the CI workflow](.github/workflows/dbt_ci.yml).

The [daily workflow](.github/workflows/daily_refresh.yml) caches the warehouse between builds, checks source freshness, builds and tests the data, generates dbt docs, and publishes a Pages artifact. On a failed build it can retain the last good site and record the failure in the public health log. A working page alone is not proof that a refresh succeeded.

The configured schedule is **6:30 AM EST / 7:30 AM EDT (America/New_York)**. That is a requested start, not a delivery guarantee; check the actual run and published build timestamp. The current post-deploy check tests the age of the live payload. It does not yet prove that the payload is the one produced by that particular run.

## Run locally

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
dbt deps --profiles-dir .

# Build the committed sample before trying the public-data window.
dbt build --profiles-dir . --full-refresh --vars '{use_sample: true}'
dbt test --profiles-dir . --select tag:post_build --vars '{check_build: true}'
```

For public data, run `dbt build --profiles-dir .`. Use `--vars '{refresh_reference: true}'` to refresh reference tables as well. The default source window and lookback rules are in [dbt_project.yml](dbt_project.yml). The daily workflow also uses the repository's source-manifest and download-retry scripts; a local run depends on upstream availability.

Exports go to `out/`; `MBTA_DUCKDB_PATH` and `MBTA_OUT_DIR` override the warehouse and export paths. No paid warehouse is required.

## Limits

The project shows where and when service differs from the schedule. It does not establish the cause of a disruption. Rider-time estimates assume random passenger arrivals and count only the first segment after boarding. Trips without a schedule match and stations without gated-entry coverage need separate interpretation.

Semantic definitions are included in the project, but their MetricFlow queries have not been validated on DuckDB. The board uses the tested marts instead.

## Sources and license

Public MBTA and MassDOT data; not affiliated with the MBTA. [Data sources and terms](data/README.md) apply to the data. Code is [MIT licensed](LICENSE).
