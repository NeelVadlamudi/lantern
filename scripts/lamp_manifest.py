#!/usr/bin/env python3
"""Build the list of LAMP subway files for the daily refresh.

MBTA's index.csv is the preferred list, but it has gone missing before (HTTP 403 from S3 on
2026-10-22), and one missing file should not stop the board from updating. So:

1. Fetch index.csv (with retries). If it reads, write it out unchanged.
2. Otherwise build the list from the predictable daily file names: one URL per date in the
   window, checked with a HEAD request. Dates that answer 200 are listed with the size and
   Last-Modified the server reports; the rest are left out.

Either way the output has the index.csv columns (size_bytes, last_modified, service_date,
file_url), so dbt reads it as source lamp.lamp_index without knowing where it came from.

A second file, --gaps, records the dates in the window that MBTA has not published (no file)
or published empty. The daily run adds it to health.json. Days left out are not lost: dbt
re-checks every date after the first loaded one on each run, so a late file is picked up.

Usage: lamp_manifest.py OUT_CSV GAPS_JSON [--days N] [--warehouse DUCKDB] [--end YYYY-MM-DD] [--base URL]
With --warehouse, the checked dates also reach back to the first service date already loaded,
so every loaded date stays listed (dbt checks that each loaded date has a file).
"""
import argparse
import csv
import datetime as dt
import email.utils
import io
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from zoneinfo import ZoneInfo

BASE = "https://performancedata.mbta.com/lamp/subway-on-time-performance-v1"
COLUMNS = ["size_bytes", "last_modified", "service_date", "file_url"]
# A LAMP Parquet file with a schema and no rows is about 3.3 kB; real days are 0.7 MB and up.
EMPTY_FILE_BYTES = 10_000


def fetch_index(base, attempts, wait):
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(f"{base}/index.csv", timeout=60) as resp:
                text = resp.read().decode("utf-8")
            rows = list(csv.DictReader(io.StringIO(text)))
            if rows and set(COLUMNS) <= set(rows[0]):
                return rows
            print("index.csv has no rows or unexpected columns", file=sys.stderr)
            return None
        except (urllib.error.URLError, TimeoutError, UnicodeDecodeError) as exc:
            print(f"index.csv attempt {attempt}: {exc}", file=sys.stderr)
            if attempt < attempts:
                time.sleep(wait * attempt)
    return None


def probe(url, attempts, wait):
    """HEAD one file: (size, last_modified) if it exists, None if the server says it does not."""
    for attempt in range(1, attempts + 1):
        try:
            req = urllib.request.Request(url, method="HEAD")
            with urllib.request.urlopen(req, timeout=30) as resp:
                size = resp.headers.get("Content-Length", "")
                modified = email.utils.parsedate_to_datetime(resp.headers["Last-Modified"])
                return size, modified.astimezone(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S+00:00")
        except urllib.error.HTTPError as exc:
            # S3 answers 403 (no list permission) or 404 for a key that does not exist.
            if exc.code in (403, 404):
                return None
            err = exc
        except (urllib.error.URLError, TimeoutError) as exc:
            err = exc
        if attempt < attempts:
            time.sleep(wait * attempt)
    raise RuntimeError(f"could not check {url}: {err}")


def probe_window(base, dates, attempts, wait):
    def one(day):
        url = f"{base}/{day}-subway-on-time-performance-v1.parquet"
        found = probe(url, attempts, wait)
        if found is None:
            return None
        return {"size_bytes": found[0], "last_modified": found[1], "service_date": day, "file_url": url}

    with ThreadPoolExecutor(max_workers=8) as pool:
        return [row for row in pool.map(one, dates) if row]


def first_loaded_date(path):
    if not path:
        return None
    try:
        import duckdb
        con = duckdb.connect(path, read_only=True)
        try:
            return con.execute("select min(service_date) from staging.stg_lamp__subway_trip_stops").fetchone()[0]
        finally:
            con.close()
    except Exception as exc:  # no warehouse yet, or no LAMP table in it
        print(f"no loaded LAMP dates read from {path}: {exc}", file=sys.stderr)
        return None


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("out_csv")
    p.add_argument("gaps_json")
    p.add_argument("--days", type=int, default=120, help="dates to check when index.csv is unavailable")
    p.add_argument("--end", help="last date to check (default: yesterday in Boston)")
    p.add_argument("--warehouse", help="DuckDB file; check back to its first loaded LAMP date")
    p.add_argument("--base", default=BASE)
    p.add_argument("--attempts", type=int, default=3)
    p.add_argument("--wait", type=float, default=10.0)
    a = p.parse_args(argv)

    end = dt.date.fromisoformat(a.end) if a.end else dt.datetime.now(ZoneInfo("America/New_York")).date() - dt.timedelta(days=1)
    start = end - dt.timedelta(days=a.days - 1)
    first_loaded = first_loaded_date(a.warehouse)
    if first_loaded and first_loaded < start:
        start = first_loaded
    window = [(start + dt.timedelta(days=i)).isoformat() for i in range((end - start).days + 1)]

    rows = fetch_index(a.base, a.attempts, a.wait)
    source = "index.csv"
    if rows is None:
        source = "file probe"
        print(f"index.csv unavailable; checking {len(window)} daily files instead", file=sys.stderr)
        rows = probe_window(a.base, window, a.attempts, a.wait)
        if not rows:
            print("no LAMP files found in the window", file=sys.stderr)
            return 1

    with open(a.out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        w.writeheader()
        w.writerows(sorted(rows, key=lambda r: r["service_date"]))

    listed = {r["service_date"]: r for r in rows}
    in_window = [d for d in window if d in listed]
    first = in_window[0] if in_window else end.isoformat()
    unpublished = [d for d in window if d >= first and d not in listed]
    empty = [d for d in in_window if str(listed[d]["size_bytes"]).isdigit() and int(listed[d]["size_bytes"]) < EMPTY_FILE_BYTES]
    gaps = {
        "list_source": source,
        "latest_published": in_window[-1] if in_window else None,
        "not_published": unpublished,
        "published_empty": empty,
    }
    with open(a.gaps_json, "w") as f:
        json.dump(gaps, f)
    print(f"LAMP file list from {source}: {len(rows)} files; not published: {unpublished or 'none'}; "
          f"empty: {empty or 'none'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
