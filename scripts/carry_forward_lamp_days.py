"""Cold-start carry-over for LAMP days MBTA has since republished empty.

MBTA republished 2026-07-16 and 2026-09-09 as empty files (2026-10-22). A warm warehouse keeps
the rows it loaded earlier, but a fresh warehouse (cache key bumped, or cache evicted) cannot
read them again, so the site would lose a day it showed before. This copies, from the previous
warehouse, the staging rows for every date inside the new warehouse's loaded range that the new
one has no rows for. _loaded_at is set to now, so the next incremental dbt build moves those
dates into fct_trip_stop_events and recomputes everything downstream with the current models.

Usage: python3 scripts/carry_forward_lamp_days.py NEW.duckdb PREVIOUS.duckdb
Prints the dates copied; copies nothing when the previous file is missing.
"""
import os
import sys

import duckdb

TABLE = "staging.stg_lamp__subway_trip_stops"


def carry_forward(new_path, prev_path):
    if not os.path.exists(prev_path):
        print(f"no previous warehouse at {prev_path}; nothing to carry over")
        return []
    con = duckdb.connect(new_path)
    con.execute(f"attach '{prev_path}' as prev (read_only)")
    cols = [r[0] for r in con.execute(
        "select column_name from information_schema.columns where table_catalog = current_database()"
        " and table_schema = 'staging' and table_name = 'stg_lamp__subway_trip_stops'"
        " order by ordinal_position").fetchall()]
    dates = [r[0] for r in con.execute(f"""
        select distinct p.service_date from prev.{TABLE} as p
        where p.service_date between (select min(service_date) from {TABLE})
                                 and (select max(service_date) from {TABLE})
          and p.service_date not in (select distinct service_date from {TABLE})
        order by 1""").fetchall()]
    if dates:
        select_cols = ", ".join("current_timestamp at time zone 'UTC' as _loaded_at" if c == "_loaded_at" else f'p."{c}"'
                                for c in cols)
        con.execute(f"""
            insert into {TABLE} ({", ".join(f'"{c}"' for c in cols)})
            select {select_cols} from prev.{TABLE} as p
            where p.service_date in (select unnest(?::date[]))""", [dates])
    con.close()
    print("carried over:", ", ".join(str(d) for d in dates) or "none")
    return dates


if __name__ == "__main__":
    carry_forward(sys.argv[1], sys.argv[2])
