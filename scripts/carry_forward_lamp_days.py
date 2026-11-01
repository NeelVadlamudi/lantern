"""Cold-start carry-over for LAMP days MBTA has since republished empty, and a gap check.

MBTA republished 2026-07-16 and 2026-09-09 as empty files (2026-10-22). A warm warehouse keeps
the rows it loaded earlier, but a fresh warehouse (cache key bumped, or cache evicted) cannot
read them again, so the site would lose a day it showed before. This copies, from the previous
warehouse, the staging rows for every date inside the new warehouse's loaded range that the new
one has no rows for. Only staging.stg_lamp__subway_trip_stops is written (never fact or mart
rows); _loaded_at is set to now, so the next incremental dbt build moves those dates into
fct_trip_stop_events and recomputes everything downstream with the current models.

After the attempt, every date in the loaded range that still has no staging rows is classed by
staging.lamp_file_reads (one row per LAMP file the build checked, from the manifest):
  - no file for the date was listed: a genuine upstream gap (MBTA never published it). Allowed;
    printed as a GitHub ::notice::.
  - a file was listed and read with 0 rows (republished empty) and no earlier rows were carried
    over: the day is lost. Printed as ::error:: and the script exits 1, so the run fails.

Usage: python3 scripts/carry_forward_lamp_days.py NEW.duckdb PREVIOUS.duckdb
"""
import os
import sys

import duckdb

TABLE = "staging.stg_lamp__subway_trip_stops"
READS = "staging.lamp_file_reads"


def _missing(con):
    return [r[0] for r in con.execute(f"""
        select d::date from range(
            (select min(service_date) from {TABLE}),
            (select max(service_date) from {TABLE}) + 1,
            interval 1 day) as t(d)
        where d::date not in (select distinct service_date from {TABLE})
        order by 1""").fetchall()]


def carry_forward(new_path, prev_path):
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
    gaps = [d for d in still if d not in listed]
    lost = [d for d in still if d in listed]
    if gaps:
        print("::notice::LAMP never published (upstream gap, allowed): " + ", ".join(map(str, gaps)))
    if lost:
        print("::error::No rows for " + ", ".join(map(str, lost)) + ": MBTA lists the file but it is "
              "empty, and no earlier rows could be carried over from a previous warehouse")
    return carried, gaps, lost


if __name__ == "__main__":
    sys.exit(1 if carry_forward(sys.argv[1], sys.argv[2])[2] else 0)
