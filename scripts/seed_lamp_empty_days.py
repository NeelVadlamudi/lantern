"""Save the staging rows of days MBTA published empty, and put them back after a cold start.

A day MBTA republished empty (2026-07-16, 2026-09-09) keeps its rows in a warm warehouse, but a
fresh warehouse cannot read them again: the only file MBTA serves for the day has no rows. The
rows used to survive only inside the warehouse cache, so one lost cache dropped the day for
good. This script keeps a second, small copy:

- export WAREHOUSE GAPS_JSON OUT.parquet: copy the staging rows of every published-empty day
  in the index summary (written by scripts/lamp_manifest.py) that the warehouse holds into one
  Parquet file. The daily workflow saves that file in its own cache on every good run.
- apply WAREHOUSE SEED.parquet: copy the saved rows back for window dates the warehouse has
  none for, through the same carry-over the previous-warehouse path uses
  (scripts/carry_forward_lamp_days.py), so the next build moves them into the facts.

Usage: python3 scripts/seed_lamp_empty_days.py export WAREHOUSE.duckdb GAPS.json OUT.parquet
       python3 scripts/seed_lamp_empty_days.py apply WAREHOUSE.duckdb SEED.parquet
"""
import argparse
import json
import os
import sys
import tempfile

import duckdb

from carry_forward_lamp_days import TABLE, carry_forward


def export(warehouse, gaps_json, out):
    """Write the staging rows of the published-empty days to a Parquet file. Returns the dates."""
    with open(gaps_json) as f:
        empty_days = json.load(f).get("published_empty", [])
    if not empty_days:
        print("no published-empty days in the index summary; nothing to save")
        return []
    con = duckdb.connect(warehouse, read_only=True)
    saved = [r[0] for r in con.execute(
        f"select distinct service_date from {TABLE} where service_date in (select unnest(?::date[])) order by 1",
        [empty_days]).fetchall()]
    if saved:
        con.execute(f"copy (select * from {TABLE} where service_date in (select unnest(?::date[]))) "
                    f"to '{out}' (format parquet)", [saved])
    con.close()
    print("saved staging rows for:", ", ".join(map(str, saved)) or "none (warehouse holds none)")
    return saved


def apply(warehouse, seed):
    """Carry the saved rows into the warehouse for window dates it has none for."""
    if not os.path.exists(seed):
        print(f"no saved empty-day rows at {seed}; nothing to put back")
        return []
    # carry_forward works between two DuckDB files, so the Parquet seed is first put in one.
    # (The path must not exist yet: DuckDB will not open an empty file as a database.)
    fd, seed_db = tempfile.mkstemp(suffix=".duckdb")
    os.close(fd)
    os.unlink(seed_db)
    try:
        con = duckdb.connect(seed_db)
        con.execute(f"create schema staging")
        con.execute(f"create table {TABLE} as select * from read_parquet('{seed}')")
        con.close()
        carried = carry_forward(warehouse, seed_db)
    finally:
        os.unlink(seed_db)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"seed_carried={len(carried)}\n")
    return carried


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["export", "apply"])
    p.add_argument("warehouse")
    p.add_argument("source", help="export: the index summary (lamp_gaps.json); apply: the seed Parquet")
    p.add_argument("out", nargs="?", help="export only: where to write the seed Parquet")
    a = p.parse_args()
    if a.mode == "export":
        if not a.out:
            p.error("export needs an output Parquet path")
        export(a.warehouse, a.source, a.out)
    else:
        apply(a.warehouse, a.source)
