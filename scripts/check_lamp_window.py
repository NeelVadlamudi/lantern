"""Gap check: every date in the reporting window must have trips, warm or cold build.

Expected dates come from the calendar, not from which LAMP files were loaded: the
reporting_window_days (dbt_project.yml, 90) consecutive dates ending on the newest service date
in staging.stg_lamp__subway_trip_stops. A date counts as present when marts.fct_trips has trips
for it. Each missing date fails the check (::error::, exit 1) unless it is on the allowed-gap
list, scripts/lamp_allowed_gaps.txt (or the path in LAMP_ALLOWED_GAPS): genuine upstream gaps,
printed as ::notice::.

Usage: python3 scripts/check_lamp_window.py WAREHOUSE.duckdb [--window-days N]
"""
import argparse
import datetime
import os
import re
import sys

import duckdb

HERE = os.path.dirname(os.path.abspath(__file__))
STAGING = "staging.stg_lamp__subway_trip_stops"
TRIPS = "marts.fct_trips"


def window_days_from_project():
    text = open(os.path.join(HERE, "..", "dbt_project.yml")).read()
    return int(re.search(r"^\s*reporting_window_days:\s*(\d+)", text, re.M).group(1))


def load_allowed(path=None):
    path = path or os.environ.get("LAMP_ALLOWED_GAPS") or os.path.join(HERE, "lamp_allowed_gaps.txt")
    allowed = set()
    if os.path.exists(path):
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if line:
                allowed.add(datetime.date.fromisoformat(line.split()[0]))
    return allowed


def check(db_path, window_days, allowed=None):
    """Returns (first, last, missing_allowed, missing_failing)."""
    allowed = load_allowed() if allowed is None else set(allowed)
    con = duckdb.connect(db_path, read_only=True)
    last = con.execute(f"select max(service_date) from {STAGING}").fetchone()[0]
    if last is None:
        con.close()
        raise SystemExit(f"::error::No LAMP service dates in {STAGING}; nothing was loaded")
    first = last - datetime.timedelta(days=window_days - 1)
    present = {r[0] for r in con.execute(
        f"select distinct service_date from {TRIPS} where service_date between ? and ?", [first, last]).fetchall()}
    staged = {r[0] for r in con.execute(
        f"select distinct service_date from {STAGING} where service_date between ? and ?", [first, last]).fetchall()}
    con.close()
    expected = [first + datetime.timedelta(days=i) for i in range(window_days)]
    missing = [d for d in expected if d not in present]
    ok_gaps = [d for d in missing if d in allowed]
    bad = [d for d in missing if d not in allowed]
    print(f"window {first} to {last} ({window_days} dates): {window_days - len(missing)} with trips")
    if ok_gaps:
        print("::notice::Known upstream LAMP gap (on the allowed-gap list): " + ", ".join(map(str, ok_gaps)))
    if bad:
        detail = ", ".join(f"{d} ({'in staging, not in fct_trips' if d in staged else 'no staging rows'})" for d in bad)
        print(f"::error::Missing service dates in the {window_days}-day window: {detail}. Add a date to "
              "scripts/lamp_allowed_gaps.txt only if MBTA never published it.")
    return first, last, ok_gaps, bad


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("db")
    p.add_argument("--window-days", type=int)
    a = p.parse_args()
    sys.exit(1 if check(a.db, a.window_days or window_days_from_project())[3] else 0)
