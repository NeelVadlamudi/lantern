#!/usr/bin/env bash
# Regression for the Nov 1 2026 refresh failure (int_scheduled_subway_trips window drift).
# Builds a scratch warehouse over a small fixed window, then runs a second incremental build
# later so the oldest loaded date (2026-07-31) leaves the reporting window (dim_dates) while
# fct_trip_stop_events keeps it. Passes when, for that date, is_matched_trip per trip and
# duplicate_events_dropped per event are identical after both runs, and
# kpi_duplicate_attribution_deterministic passes after the second run.
# Usage: scripts/tests/schedule_window_regression.sh [scratch.duckdb]   (reads real LAMP files)
set -euo pipefail
db="${1:-/tmp/schedule_window_regression.duckdb}"
rm -f "$db" "$db.wal"
export MBTA_DUCKDB_PATH="$db"
sel="+fct_trip_stop_events +int_scheduled_subway_trips"
dbt seed --profiles-dir . >/dev/null
probe() {
  python3 - "$db" <<'P'
import duckdb, sys, hashlib
c = duckdb.connect(sys.argv[1], read_only=True)
rows = c.execute("""
  select trip_stop_event_key, is_matched_trip, duplicate_events_dropped
  from marts.fct_trip_stop_events where service_date = date '2026-07-31' order by 1""").fetchall()
m = sum(1 for r in rows if r[1])
print(len(rows), m, sum(r[2] for r in rows), hashlib.sha256(repr(rows).encode()).hexdigest()[:16])
P
}
dbt run --profiles-dir . --full-refresh -s $sel \
  --vars '{lamp_start_date: 2026-07-30, lamp_end_date: 2026-08-01, reporting_window_days: 3}' >/dev/null
first=$(probe); echo "run 1 (window Jul 30-Aug 1), Jul 31: events matched dropped hash = $first"
dbt run --profiles-dir . -s $sel \
  --vars '{lamp_end_date: 2026-08-05, reporting_window_days: 3}' >/dev/null
second=$(probe); echo "run 2 (window Aug 3-5),     Jul 31: events matched dropped hash = $second"
kpi=0; dbt test --profiles-dir . -s kpi_duplicate_attribution_deterministic \
  --vars '{lamp_end_date: 2026-08-05, reporting_window_days: 3}' >/dev/null || kpi=1
[ "$first" = "$second" ] && [ "$kpi" = 0 ] && { echo "PASS"; exit 0; }
echo "FAIL (stable=$([ "$first" = "$second" ] && echo yes || echo no), kpi_test_failed=$kpi)"; exit 1
