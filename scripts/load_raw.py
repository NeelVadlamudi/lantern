"""Download MBTA public data and land it, unchanged, in the `raw` schema of the DuckDB warehouse.

Extract and load only. Cleaning, typing and business logic live in dbt.

Usage (from the repo root):
    python scripts/load_raw.py all                       # default: last 90 complete service dates
    python scripts/load_raw.py lamp --start 2026-07-09 --end 2026-10-05
    python scripts/load_raw.py lamp --since-last         # daily incremental pull
    python scripts/load_raw.py gtfs
    python scripts/load_raw.py opendata
    python scripts/load_raw.py all --sample              # offline: load the committed sample in data/sample/

Every LAMP service date is loaded with delete-then-insert, so re-running a date is safe
(LAMP republishes recent days; see data/README.md).
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import sys
import time
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

import duckdb

ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw"
SAMPLE_DIR = ROOT / "data" / "sample"
DEFAULT_DB = os.environ.get("MBTA_DUCKDB_PATH", str(ROOT / "warehouse" / "mbta.duckdb"))
TZ = ZoneInfo("America/New_York")  # service dates are Boston local dates

LAMP_BASE = "https://performancedata.mbta.com/lamp/subway-on-time-performance-v1"
LAMP_INDEX = f"{LAMP_BASE}/index.csv"
GTFS_BASE = "https://performancedata.mbta.com/lamp/gtfs_archive"
HUB_CSV = "https://mbta-massdot.opendata.arcgis.com/api/download/v1/items/{item_id}/csv?layers=0"

SUBWAY_ROUTES = ("Red", "Mattapan", "Orange", "Blue", "Green-B", "Green-C", "Green-D", "Green-E")
GTFS_FILES = ("stops", "routes", "route_patterns", "stop_times", "trips", "shapes")

OPEN_DATA = {
    # raw table name: (ArcGIS Hub item id, local file name)
    "mbta_gated_station_entries": ("001c177f07594e7c99f193dde32284c9", "gated_station_entries.csv"),
    "mbta_monthly_ridership": ("2048258a18354256a650d41f8fe4532c", "monthly_ridership_by_mode_line.csv"),
}

DEFAULT_WINDOW_DAYS = 90


def log(msg: str) -> None:
    print(f"[load_raw] {msg}", flush=True)


def fetch(url: str, dest: Path, retries: int = 3) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "mbta-dbt-loader"})
            with urllib.request.urlopen(req, timeout=300) as resp, open(tmp, "wb") as fh:
                while chunk := resp.read(1 << 20):
                    fh.write(chunk)
            tmp.replace(dest)
            return dest
        except Exception as exc:  # network errors are retried, then raised
            if attempt == retries:
                raise
            log(f"retry {attempt} for {url}: {exc}")
            time.sleep(3 * attempt)
    return dest


def connect(db_path: str) -> duckdb.DuckDBPyConnection:
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(db_path)
    con.execute("create schema if not exists raw")
    con.execute("create schema if not exists audit")
    con.execute(
        """
        create table if not exists audit.load_log (
            loaded_at timestamp, source varchar, detail varchar, rows_loaded bigint
        )
        """
    )
    return con


def audit(con, source: str, detail: str, rows: int) -> None:
    con.execute(
        "insert into audit.load_log values (current_timestamp at time zone 'UTC', ?, ?, ?)",
        [source, detail, rows],
    )


# ---------------------------------------------------------------- LAMP subway performance

def complete_through(today: dt.date | None = None) -> dt.date:
    """Last service date that is finished. A service day runs until roughly 3 AM the next morning,
    so the file for yesterday is complete by the evening it is published; today's is partial."""
    today = today or dt.datetime.now(TZ).date()
    return today - dt.timedelta(days=1)


def lamp_index() -> list[dict]:
    path = RAW_DIR / "lamp" / "index.csv"
    fetch(LAMP_INDEX, path)
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def daterange(start: dt.date, end: dt.date):
    d = start
    while d <= end:
        yield d
        d += dt.timedelta(days=1)


def max_loaded_lamp_date(con) -> dt.date | None:
    exists = con.execute(
        "select count(*) from information_schema.tables where table_schema='raw' and table_name='lamp_subway_on_time'"
    ).fetchone()[0]
    if not exists:
        return None
    v = con.execute("select max(service_date) from raw.lamp_subway_on_time").fetchone()[0]
    return dt.datetime.strptime(str(v), "%Y%m%d").date() if v else None


def load_lamp_file(con, path: Path, service_date: dt.date, source_url: str) -> int:
    sd_int = int(service_date.strftime("%Y%m%d"))
    select = f"""
        select *, '{source_url}' as _source_file, current_timestamp at time zone 'UTC' as _loaded_at
        from read_parquet('{path.as_posix()}')
    """
    exists = con.execute(
        "select count(*) from information_schema.tables where table_schema='raw' and table_name='lamp_subway_on_time'"
    ).fetchone()[0]
    con.execute("begin")
    if not exists:
        con.execute(f"create table raw.lamp_subway_on_time as {select} limit 0")
    con.execute("delete from raw.lamp_subway_on_time where service_date = ?", [sd_int])
    con.execute(f"insert into raw.lamp_subway_on_time by name {select}")
    n = con.execute("select count(*) from raw.lamp_subway_on_time where service_date = ?", [sd_int]).fetchone()[0]
    con.execute("commit")
    return n


def load_lamp(con, start: dt.date | None, end: dt.date | None, since_last: bool, sample: bool) -> None:
    if sample:
        files = sorted((SAMPLE_DIR / "lamp").glob("*-subway-on-time-performance-v1.parquet"))
        if start or end:
            files = [f for f in files if (not start or f.name[:10] >= start.isoformat()) and (not end or f.name[:10] <= end.isoformat())]
        for f in files:
            d = dt.date.fromisoformat(f.name[:10])
            n = load_lamp_file(con, f, d, f"{LAMP_BASE}/{f.name}")
            audit(con, "lamp_subway_on_time", f"sample {d}", n)
            log(f"LAMP {d}: {n:,} rows (sample)")
        return

    index = {row["service_date"]: row for row in lamp_index()}
    end = end or complete_through()
    if since_last:
        last = max_loaded_lamp_date(con)
        if last is None:
            raise SystemExit("--since-last needs an existing load; run with --start/--end or the default window first")
        # Re-pull the last loaded day too: LAMP republishes recent files.
        start = last
    start = start or end - dt.timedelta(days=DEFAULT_WINDOW_DAYS - 1)
    missing = []
    for d in daterange(start, end):
        row = index.get(d.isoformat())
        if row is None:
            missing.append(d.isoformat())
            continue
        dest = RAW_DIR / "lamp" / "subway" / Path(row["file_url"]).name
        fetch(row["file_url"], dest)
        n = load_lamp_file(con, dest, d, row["file_url"])
        audit(con, "lamp_subway_on_time", f"{d} last_modified={row['last_modified']}", n)
        log(f"LAMP {d}: {n:,} rows")
    if missing:
        log(f"not in LAMP index (skipped): {', '.join(missing)}")


# ---------------------------------------------------------------- GTFS archive (stations, routes, stop order)

def lamp_years(con) -> list[int]:
    v = con.execute("select min(service_date), max(service_date) from raw.lamp_subway_on_time").fetchone()
    if v[0] is None:
        return [dt.date.today().year]
    return list(range(int(str(v[0])[:4]), int(str(v[1])[:4]) + 1))


def load_gtfs(con, sample: bool) -> None:
    years = lamp_years(con)
    frames = {name: [] for name in GTFS_FILES}
    for year in years:
        for name in GTFS_FILES:
            if sample:
                path = SAMPLE_DIR / "gtfs" / str(year) / f"{name}.parquet"
            else:
                path = RAW_DIR / "gtfs" / str(year) / f"{name}.parquet"
                fetch(f"{GTFS_BASE}/{year}/{name}.parquet", path)
            frames[name].append(path.as_posix())

    def files(name: str) -> str:
        return "[" + ", ".join(f"'{p}'" for p in frames[name]) + "]"

    routes = ", ".join(f"'{r}'" for r in SUBWAY_ROUTES)
    con.execute("begin")
    con.execute(
        f"create or replace table raw.gtfs_routes as select *, current_timestamp at time zone 'UTC' as _loaded_at "
        f"from read_parquet({files('routes')}, union_by_name=true)"
    )
    con.execute(
        f"create or replace table raw.gtfs_stops as select *, current_timestamp at time zone 'UTC' as _loaded_at "
        f"from read_parquet({files('stops')}, union_by_name=true)"
    )
    con.execute(
        f"create or replace table raw.gtfs_route_patterns as select *, current_timestamp at time zone 'UTC' as _loaded_at "
        f"from read_parquet({files('route_patterns')}, union_by_name=true)"
    )
    # stop_times (~80 MB a year), trips and shapes are cut down to the representative trip of each
    # subway route pattern: that is all the models need (stop order and track geometry).
    con.execute(
        f"""
        create or replace table raw.gtfs_stop_times as
        select st.*, current_timestamp at time zone 'UTC' as _loaded_at
        from read_parquet({files('stop_times')}, union_by_name=true) as st
        where st.trip_id in (
            select distinct representative_trip_id from raw.gtfs_route_patterns where route_id in ({routes})
        )
        """
    )
    # trips and shapes: only the representative trips' rows and their track shapes (for the map).
    con.execute(
        f"""
        create or replace table raw.gtfs_trips as
        select t.*, current_timestamp at time zone 'UTC' as _loaded_at
        from read_parquet({files('trips')}, union_by_name=true) as t
        where t.trip_id in (
            select distinct representative_trip_id from raw.gtfs_route_patterns where route_id in ({routes})
        )
        """
    )
    con.execute(
        f"""
        create or replace table raw.gtfs_shapes as
        select s.*, current_timestamp at time zone 'UTC' as _loaded_at
        from read_parquet({files('shapes')}, union_by_name=true) as s
        where s.shape_id in (select distinct shape_id from raw.gtfs_trips)
        """
    )
    con.execute("commit")
    for t in ("gtfs_routes", "gtfs_stops", "gtfs_route_patterns", "gtfs_stop_times", "gtfs_trips", "gtfs_shapes"):
        n = con.execute(f"select count(*) from raw.{t}").fetchone()[0]
        audit(con, t, f"years={years}{' sample' if sample else ''}", n)
        log(f"{t}: {n:,} rows")


# ---------------------------------------------------------------- MBTA Open Data Portal CSVs

def load_open_data(con, sample: bool) -> None:
    for table, (item_id, fname) in OPEN_DATA.items():
        if sample:
            path = SAMPLE_DIR / "opendata" / (fname + ".gz")
        else:
            path = RAW_DIR / "opendata" / fname
            fetch(HUB_CSV.format(item_id=item_id), path)
        # all_varchar: land the file exactly as published; staging owns the types.
        con.execute(
            f"""
            create or replace table raw.{table} as
            select *, '{HUB_CSV.format(item_id=item_id)}' as _source_file,
                   current_timestamp at time zone 'UTC' as _loaded_at
            from read_csv('{path.as_posix()}', header=true, all_varchar=true)
            """
        )
        # The hub CSVs start with a UTF-8 byte order mark that ends up in the first column name.
        first = con.execute(f"select column_name from information_schema.columns where table_schema='raw' and table_name='{table}' order by ordinal_position limit 1").fetchone()[0]
        if first.startswith("\ufeff"):
            con.execute(f'alter table raw.{table} rename column "{first}" to "{first.lstrip(chr(0xFEFF))}"')
        n = con.execute(f"select count(*) from raw.{table}").fetchone()[0]
        audit(con, table, f"item={item_id}{' sample' if sample else ''}", n)
        log(f"{table}: {n:,} rows")


def main(argv: list[str]) -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("what", choices=["all", "lamp", "gtfs", "opendata"], nargs="?", default="all")
    p.add_argument("--start", type=dt.date.fromisoformat)
    p.add_argument("--end", type=dt.date.fromisoformat)
    p.add_argument("--since-last", action="store_true", help="pull from the last loaded service date to yesterday")
    p.add_argument("--sample", action="store_true", help="load the committed sample in data/sample/ (no network)")
    p.add_argument("--db", default=DEFAULT_DB)
    a = p.parse_args(argv)

    con = connect(a.db)
    if a.what in ("all", "lamp"):
        load_lamp(con, a.start, a.end, a.since_last, a.sample)
    if a.what in ("all", "gtfs"):
        load_gtfs(con, a.sample)
    if a.what in ("all", "opendata"):
        load_open_data(con, a.sample)
    con.close()


if __name__ == "__main__":
    main(sys.argv[1:])
