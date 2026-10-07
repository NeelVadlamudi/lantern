"""Rebuild the snap_gtfs_stations history by replaying past GTFS versions in date order.

A dbt snapshot only sees the state of its source at run time. The GTFS archive keeps every
schedule version, so this script points the snapshot source at each date on which a subway
station's attributes changed (plus the start of the loaded window and the latest date) and runs
`dbt snapshot` once per date, oldest first. The timestamp strategy then records the real GTFS
dates in dbt_valid_from / dbt_valid_to.

    python scripts/replay_station_snapshot.py
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
DB = os.environ.get("MBTA_DUCKDB_PATH", str(ROOT / "warehouse" / "mbta.duckdb"))
DBT = ["dbt"]


def dbt(*args: str) -> None:
    cmd = [*DBT, *args, "--profiles-dir", "."]
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=ROOT, check=True)


def replay_dates() -> list[str]:
    con = duckdb.connect(DB)
    # Dates on which any subway station's (rounded) attributes changed, inside the loaded window.
    rows = con.execute(
        """
        with lamp as (
            select min(service_date) as first_date, max(service_date) as last_date
            from staging.stg_lamp__subway_trip_stops
        ),
        stations as (
            select distinct coalesce(s.parent_station_id, st.stop_id) as station_id
            from staging.stg_gtfs__stop_times st
            join staging.stg_gtfs__stops s
              on st.stop_id = s.stop_id and st.valid_from_date = s.valid_from_date
        ),
        v as (
            select s.stop_id, s.valid_from_date,
                   s.stop_name, round(s.latitude, 5) as lat, round(s.longitude, 5) as lon,
                   s.municipality, s.wheelchair_boarding
            from staging.stg_gtfs__stops s join stations on s.stop_id = stations.station_id
        ),
        changes as (
            select valid_from_date
            from (
                select *, lag(stop_name) over w as p_name, lag(lat) over w as p_lat, lag(lon) over w as p_lon,
                       lag(municipality) over w as p_muni, lag(wheelchair_boarding) over w as p_wc,
                       row_number() over w as rn
                from v window w as (partition by stop_id order by valid_from_date)
            )
            where rn > 1 and (p_name is distinct from stop_name or p_lat is distinct from lat
                  or p_lon is distinct from lon or p_muni is distinct from municipality
                  or p_wc is distinct from wheelchair_boarding)
        )
        select distinct d from (
            select first_date as d from lamp
            union all select valid_from_date from changes, lamp
                where valid_from_date > lamp.first_date and valid_from_date <= lamp.last_date
            union all select last_date from lamp
        ) order by d
        """
    ).fetchall()
    con.execute("drop table if exists snapshots.snap_gtfs_stations")
    con.close()
    return [r[0].strftime("%Y%m%d") for r in rows]


def main() -> None:
    dates = replay_dates()
    print(f"replaying {len(dates)} GTFS as-of dates: {', '.join(dates)}")
    for d in dates:
        vars_ = "{gtfs_as_of: '" + d + "'}"
        dbt("run", "-s", "int_gtfs_stations_as_of", "--vars", vars_)
        dbt("snapshot", "-s", "snap_gtfs_stations", "--vars", vars_)
    # leave the view on the default (latest) as-of date
    dbt("run", "-s", "int_gtfs_stations_as_of")
    con = duckdb.connect(DB, read_only=True)
    changed = con.execute(
        """
        select station_id, station_name, wheelchair_boarding, latitude, longitude,
               cast(dbt_valid_from as date), cast(dbt_valid_to as date)
        from snapshots.snap_gtfs_stations
        where station_id in (select station_id from snapshots.snap_gtfs_stations group by 1 having count(*) > 1)
        order by station_id, dbt_valid_from
        """
    ).fetchall()
    total = con.execute("select count(*), count(distinct station_id) from snapshots.snap_gtfs_stations").fetchone()
    print(f"snapshot rows: {total[0]} for {total[1]} stations; stations with history:")
    for r in changed:
        print("  ", r)


if __name__ == "__main__":
    main()
