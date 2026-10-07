# Conventions

## Layers and naming

| Layer | Folder | Prefix | Materialization | Access | Rules |
|---|---|---|---|---|---|
| Sources | `models/staging/_sources.yml` | | public files read in place (`external_location`) | | No copy step. Freshness on the LAMP index. |
| Staging | `models/staging` | `stg_<source>__<entity>` | LAMP incremental; GTFS and Open Data tables kept between builds | | One model per source table. Rename, cast, convert time zones, dedupe. No joins and no business rules, except the representative-trip filter on GTFS stop_times, trips and shapes. |
| Intermediate | `models/intermediate` | `int_<entity>__<verb>` or `int_<entity>` | view | protected | Joins and business logic that more than one mart needs. Not for direct use. |
| Marts | `models/marts` | `dim_`, `fct_`, `mart_` | table (fact is incremental) | public | Contract enforced. Grain stated in the first sentence of every description. |
| Exports | `models/exports` | `board_` | external Parquet in `out/` (zstd); `board_tiles`, `board_line_totals`, `board_payload` are tables | | Column subsets of marts for the board. No logic beyond selecting, renaming and sorting, except the three JSON models, which pool and format the marts for `out/board_data.json`. |

- `dim_` = one row per thing; `fct_` = one row per event; `mart_` = an aggregate answering a
  question (line by day, station by period, and so on).
- Seeds hold reference data that does not exist in any feed (service periods, holidays, branch
  terminals, display names). They live in the `reference` schema.

## Keys and ids

- Surrogate keys are `dbt_utils.generate_surrogate_key` over the grain columns, named `<grain>_key`.
- Natural ids keep the GTFS / MBTA V3 API values so the board can join live data: stations are
  GTFS parent stations (`place-xxx`), routes are `Red`, `Orange`, `Blue`, `Green-B`, `Green-C`,
  `Green-D`, `Green-E`, `Mattapan`. Both are tested on every export.
- `line_id` is the trunk line (`Green` for all four branches). `branch_route_id` splits the Red
  Line into `Red-A` (Ashmont) and `Red-B` (Braintree).
- `date_key` is an integer `YYYYMMDD`.

## Time

- LAMP timestamps are epoch seconds. They are converted to Boston local time with
  `to_boston_time()` before a service period is assigned.
- A service date runs until about 3 AM the next calendar day. Service periods use minutes after
  midnight on the service date, so 1:30 AM is the Night period of the previous service date.
- Day type is weekday, saturday, sunday or holiday (holidays seed).

## SQL style

- Lowercase keywords and identifiers, explicit `as` for aliases, `cast(x as type)`.
- CTEs first (upstream refs near the top), then a final `select`.
- Ratios divide by `nullif(denominator, 0)` (or the `safe_ratio()` macro) so an empty
  denominator gives null, not an error.
- `sqlfluff lint models tests` must pass (config in `.sqlfluff`).
- No SQL keywords as column names (`mode`, `days`, `prior` and similar).

## Tests

- Every mart and export has a unique test on its grain.
- Foreign keys from facts and marts to dims use `relationships`.
- Problems that come from the source data and cannot be fixed in a model are tests with
  `severity: warn`. They stay visible in every run and are counted in the README; they are
  not deleted or filtered away silently.
- Business rules get singular tests in `tests/` named `assert_<rule>.sql`.
- Reusable checks are custom generic tests in `macros/generic_tests/` (`is_share`, `has_prefix`,
  `contiguous_sequence`).
- Generic test arguments go under `arguments:`.

## Variables

Thresholds live in `dbt_project.yml` vars, not in SQL: `late_trip_seconds`, `long_gap_ratio`,
`bunched_ratio`, `travel_outlier_seconds`, `incremental_lookback_days`, `rider_basis_days`,
`gtfs_as_of`. Override with `--vars '{late_trip_seconds: 600}'`.

## Changes to marts

Public marts have enforced contracts. Renaming or retyping a column is a breaking change: update
the YAML contract, the board exports and `board_payload` / `board_tiles` in the same commit, and
mention it in the commit message.
