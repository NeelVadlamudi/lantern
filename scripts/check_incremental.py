"""Prove that fct_trip_stop_events loads incrementally.

    python scripts/check_incremental.py save      # before loading a new day
    # ... python scripts/load_raw.py lamp --since-last && dbt build --profiles-dir .
    python scripts/check_incremental.py compare   # after the incremental build

`compare` fails unless:
  * the fact now has at least one service date newer than before,
  * every service date older than the reprocessing lookback kept the same row count and the same
    loaded_at (so it was not rebuilt), and
  * the fact row count for each date equals staging (nothing dropped or doubled).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import duckdb
import yaml

ROOT = Path(__file__).resolve().parents[1]
DB = os.environ.get("MBTA_DUCKDB_PATH", str(ROOT / "warehouse" / "mbta.duckdb"))
STATE = ROOT / "target" / "incremental_check.json"


def per_date(con) -> dict[str, dict]:
    rows = con.execute(
        """
        select cast(service_date as varchar), count(*), cast(max(loaded_at) as varchar)
        from marts.fct_trip_stop_events group by 1 order by 1
        """
    ).fetchall()
    return {d: {"rows": n, "loaded_at": l} for d, n, l in rows}


def main(mode: str) -> None:
    con = duckdb.connect(DB, read_only=True)
    now = per_date(con)
    if mode == "save":
        STATE.parent.mkdir(exist_ok=True)
        STATE.write_text(json.dumps(now, indent=1))
        print(f"saved {len(now)} service dates, {sum(v['rows'] for v in now.values()):,} rows")
        return

    before = json.loads(STATE.read_text())
    lookback = yaml.safe_load((ROOT / "dbt_project.yml").read_text())["vars"]["incremental_lookback_days"]
    last_before = max(before)
    new_dates = sorted(set(now) - set(before))
    assert new_dates, "no new service date was added"
    import datetime as dt
    cutoff = (dt.date.fromisoformat(last_before) - dt.timedelta(days=lookback)).isoformat()
    untouched = [d for d in before if d < cutoff]
    for d in untouched:
        assert now[d] == before[d], f"{d} changed although it is outside the lookback: {before[d]} -> {now[d]}"
    stg = dict(con.execute(
        "select cast(service_date as varchar), count(*) from staging.stg_lamp__subway_trip_stops group by 1"
    ).fetchall())
    for d, v in now.items():
        assert v["rows"] == stg.get(d), f"{d}: fact {v['rows']} rows vs staging {stg.get(d)}"
    reprocessed = [d for d in before if d >= cutoff]
    print(f"before: {len(before)} dates, {sum(v['rows'] for v in before.values()):,} rows (last {last_before})")
    print(f"after:  {len(now)} dates, {sum(v['rows'] for v in now.values()):,} rows (last {max(now)})")
    print(f"new dates: {', '.join(new_dates)} (+{sum(now[d]['rows'] for d in new_dates):,} rows)")
    print(f"reprocessed (lookback {lookback} days): {', '.join(reprocessed)}")
    print(f"untouched: {len(untouched)} dates with identical row counts and loaded_at")
    print("PASS")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "compare")
