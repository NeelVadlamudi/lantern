#!/usr/bin/env bash
# End-to-end check of the daily refresh when MBTA's LAMP bucket misbehaves, on the committed
# sample. A local web server stands in for the bucket, with no index.csv (it answers 403 like
# S3 did from 2026-10-22), so the file list has to come from the daily file names.
#   A. Day 2 is missing (days 1 and 3 published): the build passes and day 2 is a recorded gap.
#   B. Day 2 is published late: the next incremental run loads it, with no lookback.
#   C. Day 1 is republished as an empty file: the run passes and keeps day 1's rows.
# Day 3 is the first sample day (Thursday 2026-08-27). Days 1 and 2 are the sample's Friday and
# Thursday moved back to Tuesday and Wednesday of the same week (one weekday timetable; two
# different days so the board's day-to-day statistics have spread). Uses its
# own DuckDB file.
set -euo pipefail
cd "$(dirname "$0")/../.."
export MBTA_DUCKDB_PATH=warehouse/sim.duckdb
sim=warehouse/sim
bucket=$sim/lamp/subway-on-time-performance-v1
rm -rf "$sim" "$MBTA_DUCKDB_PATH"
mkdir -p "$bucket"
src=data/sample/lamp
d1=2026-08-25 d2=2026-08-26 d3=2026-08-27
f() { echo "$1-subway-on-time-performance-v1.parquet"; }

python - "$src" "$bucket" "$sim" "$d3" "$d1" "$d2" <<'PY'
import sys, duckdb
src, bucket, sim, d3, d1, d2 = sys.argv[1:]
f = lambda d: f"{d}-subway-on-time-performance-v1.parquet"
for day, from_day, back, where in ((d1, "2026-08-28", 3, bucket), (d2, d3, 1, sim)):
    duckdb.sql(f"""
    copy (
        select * replace (
            cast(strftime(cast(strptime(cast(service_date as varchar), '%Y%m%d') as date) - {back}, '%Y%m%d') as bigint) as service_date,
            move_timestamp - {back} * 86400 as move_timestamp,
            stop_timestamp - {back} * 86400 as stop_timestamp
        )
        from read_parquet('{src}/{f(from_day)}')
        -- drop a few whole trips from the copy of d3 so d2 is not identical to it
        -- (identical days give a zero spread and an infinite paired t)
        {"where hash(trip_id) % 7 != 0" if day == d2 else ""}
    ) to '{where}/{f(day)}' (format parquet)""")
duckdb.sql(f"copy (select * from read_parquet('{src}/{f(d3)}') limit 0) to '{sim}/empty.parquet' (format parquet)")
PY
cp "$src/$(f $d3)" "$bucket/"
touch -d '2026-08-29 01:00 UTC' "$bucket"/*.parquet

port=8765
python -m http.server "$port" --bind 127.0.0.1 --directory "$sim" > /dev/null 2>&1 &
server=$!
trap 'kill $server' EXIT
sleep 1
base=http://127.0.0.1:$port/lamp/subway-on-time-performance-v1

manifest() { python scripts/lamp_manifest.py "$sim/index.csv" "$sim/gaps.json" --base "$base" --end $d3 --days 3 --attempts 1; }
dates() { python - <<'PY'
import duckdb
c = duckdb.connect("warehouse/sim.duckdb", read_only=True)
print(",".join(str(r[0]) for r in c.sql("select service_date, count(*) from staging.stg_lamp__subway_trip_stops group by 1 order by 1").fetchall()))
PY
}
vars() { echo "{use_sample: true, lamp_index_url: '$sim/index.csv', lamp_end_date: $d3, $1}"; }

echo "== A. no index.csv, $d2 not published"
manifest
jq -e --arg d $d2 '.list_source == "file probe" and (.not_published | index($d)) != null' "$sim/gaps.json"
dbt build --profiles-dir . --full-refresh --vars "$(vars "lamp_start_date: $d1")"
[ "$(dates)" = "$d1,$d3" ] || { echo "loaded: $(dates)"; exit 1; }

echo "== B. $d2 published late"
mv "$sim/$(f $d2)" "$bucket/"
touch -d '2026-08-29 02:00 UTC' "$bucket/$(f $d2)"
manifest
jq -e --arg d $d2 '(.not_published | index($d)) == null' "$sim/gaps.json"
dbt build --profiles-dir . --vars "$(vars "incremental_lookback_days: 0")"
[ "$(dates)" = "$d1,$d2,$d3" ] || { echo "loaded: $(dates)"; exit 1; }
before=$(python -c "import duckdb;print(duckdb.connect('$MBTA_DUCKDB_PATH',read_only=True).sql(\"select count(*) from staging.stg_lamp__subway_trip_stops where service_date='$d1'\").fetchone()[0])")

echo "== C. $d1 republished empty, warehouse saved before lamp_file_reads existed"
# The real 2026-10-26 case: the saved warehouse had no lamp_file_reads table, so the tests
# compiled without the empty-file exclusion and flagged the days just recorded as empty.
python -c "import duckdb;duckdb.connect('$MBTA_DUCKDB_PATH').sql('drop table staging.lamp_file_reads')"
cp "$sim/empty.parquet" "$bucket/$(f $d1)"
touch "$bucket/$(f $d1)"
manifest
jq -e --arg d $d1 '.published_empty == [$d]' "$sim/gaps.json"
dbt build --profiles-dir . --vars "$(vars "incremental_lookback_days: 0")"
after=$(python -c "import duckdb;print(duckdb.connect('$MBTA_DUCKDB_PATH',read_only=True).sql(\"select count(*) from staging.stg_lamp__subway_trip_stops where service_date='$d1'\").fetchone()[0])")
[ "$before" = "$after" ] || { echo "$d1 rows changed: $before -> $after"; exit 1; }

echo "All three outage cases passed"
