"""Cold-start carry-over for LAMP days MBTA has since republished empty, and a gap check.

MBTA republished 2026-07-16 and 2026-09-09 as empty files (2026-10-22). A warm warehouse keeps
the rows it loaded earlier, but a fresh warehouse (cache key bumped, or cache evicted) cannot
read them again, so the site would lose a day it showed before. This copies, from the previous
warehouse, the staging rows for every date inside the new warehouse's loaded range that the new
one has no rows for. Only staging.stg_lamp__subway_trip_stops is written (never fact or mart
rows); _loaded_at is set to now, so the next incremental dbt build moves those dates into
fct_trip_stop_events and recomputes everything downstream with the current models.

After the attempt, every date in the loaded range that still has no staging rows fails the run
(::error:: naming the dates, exit 1) unless it is on the explicit allowed-gap list: genuine
upstream gaps, days MBTA never published, each recorded with a reason. Allowed gaps are printed
as ::notice::. The error says whether MBTA lists the file (republished empty) or not, from
staging.lamp_file_reads, so a new genuine gap can be checked and added to the list on purpose.

Allowed-gap list: scripts/lamp_allowed_gaps.txt by default, or the path in LAMP_ALLOWED_GAPS.
One date per line (YYYY-MM-DD), then the reason; # starts a comment.

Usage: python3 scripts/carry_forward_lamp_days.py NEW.duckdb PREVIOUS.duckdb
"""
import datetime
import os
import sys

import duckdb

TABLE = "staging.stg_lamp__subway_trip_stops"
READS = "staging.lamp_file_reads"
DEFAULT_ALLOWED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lamp_allowed_gaps.txt")


def load_allowed(path=None):
    path = path or os.environ.get("LAMP_ALLOWED_GAPS") or DEFAULT_ALLOWED
    allowed = set()
    if os.path.exists(path):
        for line in open(path):
            line = line.split("#", 1)[0].strip()
            if line:
                allowed.add(datetime.date.fromisoformat(line.split()[0]))
    return allowed


def _missing(con):
    return [r[0] for r in con.execute(f"""
        select d::date from range(
            (select min(service_date) from {TABLE}),
            (select max(service_date) from {TABLE}) + 1,
            interval 1 day) as t(d)
        where d::date not in (select distinct service_date from {TABLE})
        order by 1""").fetchall()]


def carry_forward(new_path, prev_path, allowed=None):
    """Returns (carried, upstream_gaps, lost) as lists of dates."""
    con = duckdb.connect(new_path)
    missing = _missing(con)
    carried = []
    if not os.path.exists(prev_path):
        print(f"no previous warehouse at {prev_path}; nothing can be carried over")
    elif missing:
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
    print("carried over:", ", ".join(map(str, carried)) or "none")
    still = _missing(con)
    listed = set()
    if still:
        listed = {r[0] for r in con.execute(
            f"select distinct service_date from {READS} where service_date in (select unnest(?::date[]))",
            [still]).fetchall()}
    con.close()
    allowed = load_allowed() if allowed is None else set(allowed)
    gaps = [d for d in still if d in allowed]
    lost = [d for d in still if d not in allowed]
    if gaps:
        print("::notice::Known upstream LAMP gap (on the allowed-gap list): " + ", ".join(map(str, gaps)))
    if lost:
        empty = [str(d) for d in lost if d in listed]
        unlisted = [str(d) for d in lost if d not in listed]
        why = []
        if empty:
            why.append("republished empty (MBTA lists the file, 0 rows): " + ", ".join(empty))
        if unlisted:
            why.append("not published by MBTA: " + ", ".join(unlisted))
        print("::error::No staging rows for " + ", ".join(map(str, lost)) + " and no earlier rows could be "
              "carried over; " + "; ".join(why) + ". Add a date to scripts/lamp_allowed_gaps.txt only "
              "if it is a genuine upstream gap.")
    return carried, gaps, lost


if __name__ == "__main__":
    sys.exit(1 if carry_forward(sys.argv[1], sys.argv[2])[2] else 0)
