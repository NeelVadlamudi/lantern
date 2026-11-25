"""Gap check: every date in the reporting window must have trips, warm or cold build.

Expected dates come from the calendar, not from which LAMP files were loaded: the
reporting_window_days (dbt_project.yml, 90) consecutive dates ending on the newest service date
in staging.stg_lamp__subway_trip_stops. A date counts as present when marts.fct_trips has trips
for it. A missing date is judged in tiers, like a freshness threshold:

- On the allowed-gap list (scripts/lamp_allowed_gaps.txt, or the path in LAMP_ALLOWED_GAPS):
  a known gap with its evidence recorded; printed as ::notice::, never fails.
- MBTA's index says the date was never published (the --gaps-json summary written by
  scripts/lamp_manifest.py) and it is older than GRACE_DAYS: MBTA is not going to publish it
  late, so it is printed as ::warning:: and the run still publishes. Before this tier existed,
  one such day would have failed every run and frozen the board on old data.
- Anything else fails (::error::, exit 1): a date MBTA did publish is our job to load, and a
  never-published date inside the grace window may still be on its way.

Without --gaps-json there is no index summary to judge against, so every missing date that is
not on the allowed-gap list fails, as before.

Usage: python3 scripts/check_lamp_window.py WAREHOUSE.duckdb [--window-days N]
       [--gaps-json warehouse/lamp_gaps.json]
"""
import argparse
import datetime
import json
import os
import re
import sys

import duckdb

HERE = os.path.dirname(os.path.abspath(__file__))
STAGING = "staging.stg_lamp__subway_trip_stops"
TRIPS = "marts.fct_trips"
# A date MBTA has not published within this many days of the newest loaded date is treated as
# still on its way; older than this, it is treated as never coming.
GRACE_DAYS = 3


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


def load_gaps(path):
    """The index summary from lamp_manifest.py: (not_published, published_empty, latest).

    Dates are ISO strings in the file. Returns None when there is no readable summary, so the
    caller judges gaps the strict way.
    """
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            gaps = json.load(f)
        parse = lambda days: {datetime.date.fromisoformat(d) for d in days}
        latest = gaps.get("latest_published")
        return (parse(gaps.get("not_published", [])), parse(gaps.get("published_empty", [])),
                datetime.date.fromisoformat(latest) if latest else None)
    except (ValueError, TypeError) as exc:
        print(f"could not read the LAMP index summary at {path} ({exc}); judging gaps without it")
        return None


def check(db_path, window_days, allowed=None, gaps=None):
    """Returns (first, last, missing_allowed, missing_warned, missing_failing)."""
    allowed = load_allowed() if allowed is None else set(allowed)
    not_published, _, latest_published = gaps if gaps else (set(), set(), None)
    if not os.path.exists(db_path):
        raise SystemExit(f"::error::No warehouse at {db_path}; the reporting window cannot be checked")
    con = duckdb.connect(db_path, read_only=True)
    found = {r[0] for r in con.execute(
        "select table_schema || '.' || table_name from information_schema.tables").fetchall()}
    if not {STAGING, TRIPS} <= found:
        con.close()
        raise SystemExit(f"::error::{db_path} has no {STAGING} or {TRIPS}; the reporting window cannot be checked")
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
    rest = [d for d in missing if d not in allowed]
    warned = [d for d in rest if d in not_published and (last - d).days > GRACE_DAYS]
    bad = [d for d in rest if d not in warned]
    print(f"window {first} to {last} ({window_days} dates): {window_days - len(missing)} with trips")
    if gaps:
        print(f"newest service date in the warehouse: {last}")
        print(f"newest service date MBTA has published: {latest_published}")
    if ok_gaps:
        print("::notice::Known upstream LAMP gap (on the allowed-gap list): " + ", ".join(map(str, ok_gaps)))
    if warned:
        print(f"::warning::Service dates MBTA has not published (past the {GRACE_DAYS}-day grace "
              "window, so the run still publishes): " + ", ".join(map(str, warned)))
    if bad:
        detail = ", ".join(f"{d} ({'in staging, not in fct_trips' if d in staged else 'no staging rows'})" for d in bad)
        print(f"::error::Missing service dates in the {window_days}-day window: {detail}. Add a date to "
              "scripts/lamp_allowed_gaps.txt only if MBTA never published it, or published it in a "
              "form whose rows can no longer be loaded (say which, with the index evidence).")
    return first, last, ok_gaps, warned, bad


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("db")
    p.add_argument("--window-days", type=int)
    p.add_argument("--gaps-json", help="index summary written by scripts/lamp_manifest.py")
    a = p.parse_args()
    gaps = load_gaps(a.gaps_json)
    if a.gaps_json and gaps is None:
        print(f"no readable LAMP index summary at {a.gaps_json}; judging gaps the strict way")
    sys.exit(1 if check(a.db, a.window_days or window_days_from_project(), gaps=gaps)[4] else 0)
