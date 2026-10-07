"""Recompute the board's headline numbers straight from the fact tables and check them against
out/board_data.json. Also checks the build block and the map block. Exits non-zero on any mismatch.

    python scripts/verify_kpis.py
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
DB = os.environ.get("MBTA_DUCKDB_PATH", str(ROOT / "warehouse" / "mbta.duckdb"))
ROUTE_IDS = {"Red", "Mattapan", "Orange", "Green-B", "Green-C", "Green-D", "Green-E", "Blue"}
OUT = Path(os.environ.get("MBTA_OUT_DIR", ROOT / "out"))
failures: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  ' + detail if detail else ''}")
    if not ok:
        failures.append(name)


def close(a, b, tol=1e-4) -> bool:
    return a is not None and b is not None and abs(float(a) - float(b)) <= tol


def main() -> None:
    board = json.loads((OUT / "board_data.json").read_text())
    tiles = {t["id"]: t for t in board["tiles"]}
    con = duckdb.connect(DB, read_only=True)

    # --- tiles, recomputed from fct_trips / fct_trip_stop_events (not from the marts)
    late, excess, n_compared, rel = con.execute("""
        select avg(is_late_trip::int), avg(trip_excess_seconds), count(*),
               sum(trip_excess_seconds) / sum(trip_scheduled_seconds)
        from marts.fct_trips where compared_segments > 0
    """).fetchone()
    check("tile late_trip_share", close(tiles["late_trip_share"]["value"], late), f"board={tiles['late_trip_share']['value']} fact={late:.4f} (n={n_compared:,})")
    t = tiles["avg_trip_excess_seconds"]
    check("tile avg_trip_excess_seconds (per trip)", close(t["value"], excess, 0.06) and close(t["share_of_scheduled"], rel),
          f"board={t['value']} s, {t['share_of_scheduled']} of schedule; fact={excess:.2f} s, {rel:.4f}")

    # line figures use the same grain as the system figure: per compared trip, from fct_trips
    for ln in board["lines"]:
        fl, fe = con.execute("""
            select avg(is_late_trip::int), avg(trip_excess_seconds) from marts.fct_trips
            where compared_segments > 0 and route_id = ?""", [ln["route_id"]]).fetchone()
        check(f"line {ln['route_id']} per-trip late share and excess", close(ln["late_trip_share"], fl) and close(ln["avg_trip_excess_seconds"], fe, 0.06),
              f"board={ln['late_trip_share']}, {ln['avg_trip_excess_seconds']} s; fact={fl:.4f}, {fe:.2f} s")

    # entries during long gaps, recomputed from gated entries and the fact table
    # (not from the marts): weekday cells of station x line x service period, each entry once
    exp_val, exp_entries = con.execute("""
        with riders as (
            select station_id, line_id, service_period_id, avg_daily_gated_entries as entries
            from intermediate.int_station_period_riders where day_type = 'weekday'
        ),
        gaps as (
            select e.station_id, e.line_id, e.service_period_id,
                   avg(e.is_long_gap::int) filter (where e.has_headway_comparison) as share
            from marts.fct_trip_stop_events e join marts.dim_dates d using (date_key)
            where d.day_type = 'weekday' group by all
        )
        select sum(riders.entries * gaps.share), sum(riders.entries) filter (where gaps.station_id is not null)
        from riders join gaps using (station_id, line_id, service_period_id)
    """).fetchone()
    t = tiles["weekday_entries_in_long_gaps"]
    check("tile weekday_entries_in_long_gaps", abs(t["value"] - exp_val) <= max(1, 0.001 * exp_val),
          f"board={t['value']:,} fact={exp_val:,.0f} of {exp_entries:,.0f} weekday entries")
    dup = con.execute("""
        select count(*) from (select station_id, line_id, day_type, service_period_id, count(*) n
        from intermediate.int_station_period_riders group by all having count(*) > 1)
    """).fetchone()[0]
    check("rider cells not duplicated", dup == 0, f"duplicate station/line/day type/period cells: {dup}")

    gap = con.execute("select avg(is_long_gap::int) from marts.fct_trip_stop_events where has_headway_comparison").fetchone()[0]
    check("tile long_gap_share", close(tiles["long_gap_share"]["value"], gap), f"board={tiles['long_gap_share']['value']} fact={gap:.4f}")

    worst_route, worst_share = con.execute("""
        select route_id, avg(is_late_trip::int) as s from marts.fct_trips where compared_segments > 0
        group by 1 order by s desc limit 1
    """).fetchone()
    check("tile worst_line", tiles["worst_line"]["value"] == worst_route and close(tiles["worst_line"]["metric_value"], worst_share),
          f"board={tiles['worst_line']['value']} {tiles['worst_line']['metric_value']} fact={worst_route} {worst_share:.4f}")

    last = con.execute("select cast(max(service_date) as varchar) from marts.fct_trip_stop_events").fetchone()[0]
    check("tile freshness", tiles["freshness"]["value"] == last, f"board={tiles['freshness']['value']} fact={last}")

    # --- coverage block, recomputed from the fact table
    cv = board["coverage"]
    n, no_tr, no_hw, no_any = con.execute("""
        select count(*),
               count(*) filter (where coalesce(scheduled_run_seconds, 0) <= 0),
               count(*) filter (where coalesce(scheduled_headway_seconds, 0) <= 0),
               count(*) filter (where coalesce(scheduled_run_seconds, 0) <= 0 and coalesce(scheduled_headway_seconds, 0) <= 0)
        from marts.fct_trip_stop_events
    """).fetchone()
    sy = cv["system"]
    check("coverage system counts", (sy["trip_stop_events"], sy["without_scheduled_travel"], sy["without_scheduled_headway"], sy["without_any_schedule"]) == (n, no_tr, no_hw, no_any),
          f"events={n:,} no travel={no_tr:,} no headway={no_hw:,} neither={no_any:,}")
    check("coverage by route adds up", sum(x["trip_stop_events"] for x in cv["by_route"]) == n and len(cv["by_route"]) == 8)
    ids = cv["stations_without_gated_entries"]["station_ids"]
    gated = {row[0] for row in con.execute("select distinct station_id from intermediate.int_station_period_riders").fetchall()}
    check("ungated station ids are place-* and have no gated entries", all(i.startswith("place-") for i in ids) and not (set(ids) & gated),
          f"{len(ids)} stations without gated entries")

    # --- build block
    b = board["build"]
    check("build tests_failed == 0", b["tests_failed"] == 0, f"failed={b['tests_failed']}")
    check("build tests add up", b["tests_passed"] + b["tests_warned"] + b["tests_failed"] + b["tests_skipped"] == b["tests_total"])
    check("build has incremental fact", "fct_trip_stop_events" in b["incremental_models"])

    # --- map block
    m = board["map"]
    stations = {s["station_id"]: s for s in m["stations"]}
    no_coords = [sid for sid, s in stations.items() if s["lat"] is None or s["lon"] is None]
    check("map stations all have coordinates", not no_coords, f"{len(stations)} stations, missing: {no_coords or 'none'}")
    in_box = [sid for sid, s in stations.items() if s["lat"] is not None and not (42.1 < s["lat"] < 42.5 and -71.3 < s["lon"] < -70.9)]
    check("map coordinates inside Greater Boston", not in_box, str(in_box or ""))
    bad_ids = [sid for sid in stations if not sid.startswith("place-")]
    check("map station ids are place-*", not bad_ids, str(bad_ids or ""))
    bad_routes = sorted({rid for s in m["stations"] for rid in s["route_ids"]} - ROUTE_IDS
                        | {ln["route_id"] for ln in m["lines"]} - ROUTE_IDS)
    check("map route ids are V3 subway route ids", not bad_routes, str(bad_routes or ""))

    db_seq = {}
    for branch, direction, order, sid in con.execute(
        "select branch_route_id, direction_id, stop_order, station_id from marts.mart_line_stop_sequence order by 1, 2, 3"
    ).fetchall():
        db_seq.setdefault((branch, direction), []).append((order, sid))
    for ln in m["lines"]:
        key = (ln["branch_route_id"], ln["direction_id"])
        seq = db_seq.get(key, [])
        orders = [o for o, _ in seq]
        contiguous = orders == list(range(1, len(orders) + 1))
        matches = [sid for _, sid in seq] == ln["stops"]
        on_map = all(sid in stations for sid in ln["stops"])
        no_repeat = len(set(ln["stops"])) == len(ln["stops"])
        check(f"map line {key[0]} dir {key[1]} stop sequence contiguous",
              contiguous and matches and on_map and no_repeat,
              f"{len(ln['stops'])} stops, {ln['stops'][0]} -> {ln['stops'][-1]}")
    cov = m["coverage"]
    no_shape = [f"{ln['branch_route_id']}/{ln['direction_id']}" for ln in m["lines"] if len(ln.get("shape") or []) < 2]
    check("map lines all have track shapes", not no_shape, f"missing: {no_shape or 'none'}")
    off_box = [ln["branch_route_id"] for ln in m["lines"] for lon, lat in (ln.get("shape") or [])
               if not (-71.4 < lon < -70.8 and 42.1 < lat < 42.6)]
    check("track shape points inside Greater Boston", not off_box, str(sorted(set(off_box)) or ""))
    check("map has every branch", not cov["branches_missing"], f"missing: {cov['branches_missing'] or 'none'}")

    # --- Parquet files listed in the board exist and match
    for f in board["files"]:
        path = OUT / f["file"]
        n = con.execute(f"select count(*) from read_parquet('{path.as_posix()}')").fetchone()[0] if path.exists() else None
        check(f"file {f['file']}", n == f["rows"], f"{f['bytes']:,} bytes, {n} rows")

    if failures:
        print(f"\n{len(failures)} check(s) failed")
        sys.exit(1)
    print("\nALL PASS")


if __name__ == "__main__":
    main()
