# Failure log

Break tests run on scratch copies of the repo (sample data, two service dates, plus edited
inputs). Each row: the case, what happened, why, the fix, and the test that now catches it.
"Fails" means the build stops with an error, so the daily workflow keeps the last good site.

| # | Case | What broke | Cause | Fix | Test |
|---|------|-----------|-------|-----|------|
| 1 | Missing day inside the window | Build fails | No rows for 2026-08-28 between two loaded days | Already caught | `assert_no_missing_service_dates` |
| 2 | Missing first day (start date has no file) | Build passed with a shorter window | dim_dates starts at the first date with rows, so the gap test cannot see it | Check the loaded window against lamp_start_date / lamp_end_date | `assert_window_matches_request` (new) |
| 3 | Empty file for the last day (zero trips that day) | Build passed and the board quietly ended a day early | Same as 2: the window just stopped at the last date with rows | Every date the index lists up to the window end must have rows | `assert_index_dates_loaded` (new) |
| 4 | Source URL down | Build fails: `IO Error: Could not connect to server` in stg_lamp__subway_trip_stops | No file at the URL | Already fails; the workflow keeps the last good site | dbt model error |
| 5 | Source returns garbage (HTML page instead of Parquet) | Build fails: `No magic bytes found` | Not a Parquet file | Already fails | dbt model error |
| 6 | Index or CSV returns garbage (HTML) | Build fails on the source tests / staging columns | No expected columns | Already fails; on a reference refresh the old rows are kept (the delete rolls back) | `source_not_null_lamp_lamp_index_*`, staging binder error |
| 7 | Duplicate rows in a day's file | No break: counts identical to the clean build | Staging keeps one row per trip-stop | None needed | staging unique grain test |
| 8 | The same day listed twice in the index | No break | File read twice, deduplicated in staging | None needed | staging unique grain test |
| 9 | One line with zero trips on a day (Mattapan removed from 2026-08-28) | No break; Mattapan that day: 268 scheduled, 0 compared, `is_low_completeness` true | A real outage looks the same, so it is flagged, not failed | Completeness model | `kpi_completeness` (new) |
| 10 | Latest day is a holiday | Card sentence was null (blank card) | No earlier holiday to compare with, so the typical value is null | Sentence says there is nothing to compare with | `kpi_latest_day_sentences` (new) |
| 11 | DST change, 2026-11-01 | No error, but the two 1:30 AMs both land in service hour 25 of 2026-10-31 | service_hour reads the Boston wall clock | Kept (labels match the clock) and flagged: `dim_dates.dst_extra_hours` = +1 on 2026-10-31, -1 on 2026-03-07 | `assert_dst_service_hours` (new) |
| 12 | Late-arriving data (file republished after it was loaded, outside the lookback) | Old rows kept: 42,845 rows for 2026-08-27 instead of the republished 38,561 | Incremental runs only re-read the last 3 days | Re-read any loaded date whose index last_modified is later than its load time | `assert_no_republished_files_missed` (new) |
| 13 | Future dates (index lists 2026-12-01) | No break | The window ends at yesterday in Boston | None needed | `assert_index_dates_loaded` window end |
| 14 | Future dates inside a file (rows dated 2026-12-01) | Build fails | Bad rows | New test names the cause directly | `assert_no_future_service_dates` (new) |
| 15 | Column renamed in the Commuter Rail file (`otp_numerator` to `otp_num`) | Build fails: `Referenced column "otp_numerator" not found` | Schema change upstream | Already fails; existing rows kept on refresh | dbt model error |
| 16 | Column renamed in the survey file (`weighted_percent` to `weighted_pct`) | Build fails: `Referenced column "weighted_percent" not found` | Same | Already fails | dbt model error |
| 17 | Workflow files did not parse as YAML | GitHub would reject both workflows | `run:` lines with `--vars '{a: b}'` are not valid plain YAML | Those lines are now block scalars (`run: \|`) | parsed in the checks before commit |

Note on 12: in the scratch test the republished file was given a last_modified later than the
load, so the test still reported it after the reload; with real timestamps the reload clears it.
