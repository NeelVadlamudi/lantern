"""Build the small committed sample in data/sample/ from a full local load.

CI runs on this sample so pull requests build offline in about a minute. It is real MBTA data,
cut down: two LAMP service dates, the subway-only part of the GTFS archive, and two months of
gated entries. Regenerate after a full load with:

    python scripts/make_sample.py --dates 2026-08-27 2026-08-28
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
SAMPLE = ROOT / "data" / "sample"
LAMP_BASE = "https://performancedata.mbta.com/lamp/subway-on-time-performance-v1"
SUBWAY = "('Red','Mattapan','Orange','Blue','Green-B','Green-C','Green-D','Green-E')"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--dates", nargs="+", required=True)
    p.add_argument("--gated-from", default="2026-07-01")
    a = p.parse_args()

    import sys
    sys.path.insert(0, str(ROOT / "scripts"))
    from load_raw import fetch  # same downloader as the loader

    (SAMPLE / "lamp").mkdir(parents=True, exist_ok=True)
    for d in a.dates:
        name = f"{d}-subway-on-time-performance-v1.parquet"
        src = RAW / "lamp" / "subway" / name
        if not src.exists():
            fetch(f"{LAMP_BASE}/{name}", src)
        shutil.copy(src, SAMPLE / "lamp" / name)

    con = duckdb.connect()
    years = sorted({d[:4] for d in a.dates})
    for y in years:
        src = RAW / "gtfs" / y
        dst = SAMPLE / "gtfs" / y
        dst.mkdir(parents=True, exist_ok=True)
        con.execute(f"create or replace view rp as select * from read_parquet('{src}/route_patterns.parquet') where route_id in {SUBWAY}")
        con.execute(f"create or replace view st as select * from read_parquet('{src}/stop_times.parquet') where trip_id in (select representative_trip_id from rp)")
        con.execute(f"""create or replace view stp as
            select * from read_parquet('{src}/stops.parquet')
            where stop_id in (select stop_id from st)
               or stop_id in (select parent_station from read_parquet('{src}/stops.parquet') where stop_id in (select stop_id from st))""")
        con.execute(f"create or replace view tr as select * from read_parquet('{src}/trips.parquet') where trip_id in (select representative_trip_id from rp)")
        con.execute(f"create or replace view sh as select * from read_parquet('{src}/shapes.parquet') where shape_id in (select shape_id from tr)")
        for name, view in [("route_patterns", "rp"), ("stop_times", "st"), ("stops", "stp"), ("trips", "tr"), ("shapes", "sh")]:
            con.execute(f"copy (select * from {view}) to '{dst}/{name}.parquet' (format parquet, compression zstd)")
        con.execute(f"copy (select * from read_parquet('{src}/routes.parquet') where route_id in {SUBWAY}) to '{dst}/routes.parquet' (format parquet, compression zstd)")

    od = SAMPLE / "opendata"
    od.mkdir(parents=True, exist_ok=True)
    last = max(a.dates).replace("-", "/")
    con.execute(f"""copy (
        select * from read_csv('{RAW}/opendata/gated_station_entries.csv', header=true, all_varchar=true)
        where left(service_date, 10) between '{a.gated_from.replace('-', '/')}' and '{last}'
    ) to '{od}/gated_station_entries.csv.gz' (header, compression gzip)""")
    con.execute(f"""copy (
        select * from read_csv('{RAW}/opendata/monthly_ridership_by_mode_line.csv', header=true, all_varchar=true)
    ) to '{od}/monthly_ridership_by_mode_line.csv.gz' (header, compression gzip)""")
    total = sum(f.stat().st_size for f in SAMPLE.rglob("*") if f.is_file())
    print(f"sample written to {SAMPLE} ({total / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
