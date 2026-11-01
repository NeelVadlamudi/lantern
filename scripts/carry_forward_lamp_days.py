"""Carry-over of LAMP days a previous warehouse has and the current one lacks.

MBTA republished 2026-07-16 and 2026-09-09 as empty files (2026-10-22). A warm warehouse keeps
the rows it loaded earlier, but a fresh warehouse (cache key bumped, or cache evicted) cannot
read them again, so the site would lose a day it showed before. For every date in the reporting
window (reporting_window_days consecutive dates ending on the newest staging date) that has no
staging rows, this copies the previous warehouse's staging rows when it has them. Only
staging.stg_lamp__subway_trip_stops is written (never fact or mart rows); _loaded_at is set to
now, so the next incremental dbt build moves those dates into fct_trip_stop_events and
recomputes everything downstream with the current models.

It does not judge gaps: scripts/check_lamp_window.py runs after every build and fails the run
for missing days that are not on the allowed-gap list.

Prints the carried dates; with GITHUB_OUTPUT set, also writes carried=<count>.
Usage: python3 scripts/carry_forward_lamp_days.py NEW.duckdb PREVIOUS.duckdb [--window-days N]
"""
import argparse
import datetime
import os

import duckdb

from check_lamp_window import window_days_from_project

TABLE = "staging.stg_lamp__subway_trip_stops"


def missing_in_window(con, window_days):
    last = con.execute(f"select max(service_date) from {TABLE}").fetchone()[0]
    if last is None:
        return []
    first = last - datetime.timedelta(days=window_days - 1)
    have = {r[0] for r in con.execute(
        f"select distinct service_date from {TABLE} where service_date >= ?", [first]).fetchall()}
    return [first + datetime.timedelta(days=i) for i in range(window_days)
            if first + datetime.timedelta(days=i) not in have]


def carry_forward(new_path, prev_path, window_days=None):
    """Returns the list of dates copied from the previous warehouse."""
    window_days = window_days or window_days_from_project()
    if not os.path.exists(prev_path):
        print(f"no previous warehouse at {prev_path}; nothing to carry over")
        return []
    con = duckdb.connect(new_path)
    missing = missing_in_window(con, window_days)
    carried = []
    if missing:
        con.execute(f"attach '{prev_path}' as prev (read_only)")
        cols = [r[0] for r in con.execute(
            "select column_name from information_schema.columns where table_catalog = current_database()"
            " and table_schema = 'staging' and table_name = 'stg_lamp__subway_trip_stops'"
            " order by ordinal_position").fetchall()]
        carried = [r[0] for r in con.execute(
            f"select distinct service_date from prev.{TABLE} where service_date in (select unnest(?::date[])) order by 1",
            [missing]).fetchall()]
        if carried:
            select_cols = ", ".join(
                "current_timestamp at time zone 'UTC' as _loaded_at" if c == "_loaded_at" else f'p."{c}"'
                for c in cols)
            con.execute(f"""
                insert into {TABLE} ({", ".join(f'"{c}"' for c in cols)})
                select {select_cols} from prev.{TABLE} as p
                where p.service_date in (select unnest(?::date[]))""", [carried])
    con.close()
    print("window dates without staging rows:", ", ".join(map(str, missing)) or "none")
    print("carried over:", ", ".join(map(str, carried)) or "none")
    return carried


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("new")
    p.add_argument("prev")
    p.add_argument("--window-days", type=int)
    a = p.parse_args()
    carried = carry_forward(a.new, a.prev, a.window_days)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"carried={len(carried)}\n")
