"""Write out/board_data.json for the glance board. Run right after `dbt build`.

Reads the marts from DuckDB and the build artifacts from target/ (run_results.json and
manifest.json from the same build). Every number comes from a model or an artifact; nothing is
typed in by hand. The Parquet files the board queries live next to it in out/ and are written by
the dbt models in models/exports/.

    python scripts/export_board.py
"""
from __future__ import annotations

import datetime as dt
import json
import os
from collections import Counter, defaultdict
from pathlib import Path
from zoneinfo import ZoneInfo

import duckdb
import yaml

ROOT = Path(__file__).resolve().parents[1]
DB = os.environ.get("MBTA_DUCKDB_PATH", str(ROOT / "warehouse" / "mbta.duckdb"))
OUT = Path(os.environ.get("MBTA_OUT_DIR", ROOT / "out"))
TARGET = ROOT / "target"
BOSTON = ZoneInfo("America/New_York")
ROUTE_IDS = ["Red", "Mattapan", "Orange", "Green-B", "Green-C", "Green-D", "Green-E", "Blue"]

SOURCES = [
    {
        "name": "MBTA LAMP subway on-time performance",
        "url": "https://performancedata.mbta.com/lamp/subway-on-time-performance-v1/index.csv",
        "used_for": "Train arrivals, run times and headways (fact table)",
        "terms": "MassDOT Developers License Agreement; see data/README.md",
    },
    {
        "name": "MBTA LAMP GTFS archive",
        "url": "https://performancedata.mbta.com/lamp/gtfs_archive/",
        "used_for": "Stations, coordinates, routes, colors, stop order",
        "terms": "MassDOT Developers License Agreement; see data/README.md",
    },
    {
        "name": "MBTA Gated Station Entries (MBTA Open Data Portal)",
        "url": "https://mbta-massdot.opendata.arcgis.com/datasets/001c177f07594e7c99f193dde32284c9",
        "used_for": "Rider exposure weights",
        "terms": "CC0 (as listed on the item)",
    },
    {
        "name": "MBTA Monthly Ridership by Mode and Line (MBTA Open Data Portal)",
        "url": "https://mbta-massdot.opendata.arcgis.com/datasets/2048258a18354256a650d41f8fe4532c",
        "used_for": "Context (staged, not on the board yet)",
        "terms": "CC0 (as listed on the item)",
    },
]

GLOSSARY = [
    {"term": "Service date", "meaning": "The MBTA's operating day. Trains running after midnight still count toward the day they started."},
    {"term": "Scheduled run time", "meaning": "How long the published schedule gives a train to get from one stop to the next."},
    {"term": "Excess travel", "meaning": "Actual time between stops minus scheduled time. Positive means slower than the schedule."},
    {"term": "Late trip", "meaning": "A train run whose actual time between its first and last compared stops was more than 5 minutes longer than scheduled. The same 5-minute rule applies on every line, so long lines are more exposed to it."},
    {"term": "Excess per trip", "meaning": "For one train run, the sum of (actual minus scheduled) time over its compared stop-to-stop segments. Averaged per trip, not per stop."},
    {"term": "Excess vs schedule", "meaning": "Total excess time divided by total scheduled run time. Compares lines of different length on an equal footing."},
    {"term": "Headway", "meaning": "The gap between one train leaving a station and the next train on the same line leaving it."},
    {"term": "Long gap", "meaning": "A wait more than 1.5 times the scheduled gap, e.g. 12+ minutes when trains are due every 8."},
    {"term": "Bunched", "meaning": "A train leaving a station less than half the scheduled gap after the train before it."},
    {"term": "Headway adherence", "meaning": "Share of gaps between half and 1.5 times the scheduled gap."},
    {"term": "Gated entries", "meaning": "Fare-gate entries at a station, from MBTA's published counts. Each entry is counted once, on one line. One person can make several entries a day, so entries are not riders."},
    {"term": "Service period", "meaning": "MBTA time-of-day bands from its Service Delivery Policy, e.g. AM Peak 7:00-8:59."},
    {"term": "Entries during long gaps", "meaning": "For each station, line and time of day: average gated entries times the share of train departures that came after a long gap, summed. An estimate of how many entries happen during long gaps, not a head count of people who waited."},
]


def rows(con, sql: str) -> list[dict]:
    cur = con.execute(sql)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def one(con, sql: str) -> dict:
    return rows(con, sql)[0]


def r(x, n=4):
    return None if x is None else round(float(x), n)


def pct(x, n=1):
    return None if x is None else f"{100 * x:.{n}f}%"


# ------------------------------------------------------------------ build block

def build_block() -> dict:
    run_results = json.loads((TARGET / "run_results.json").read_text())
    manifest = json.loads((TARGET / "manifest.json").read_text())
    project = manifest["metadata"]["project_name"] if "project_name" in manifest["metadata"] else "mbta_reliability"
    results = {res["unique_id"]: res["status"] for res in run_results["results"]}
    tests = {k: v for k, v in results.items() if k.startswith("test.")}
    if not tests:
        raise SystemExit("target/run_results.json has no test results; run `dbt build` before this script")

    nodes = manifest["nodes"]
    models = {k: n for k, n in nodes.items() if n["resource_type"] == "model" and n["package_name"] == "mbta_reliability"}
    layer_of = {k: n["fqn"][1] if len(n["fqn"]) > 2 else "root" for k, n in models.items()}
    layer_order = ["staging", "intermediate", "marts", "exports"]

    edges = Counter()
    model_edges = []
    for k, n in models.items():
        for dep in n["depends_on"]["nodes"]:
            if dep in models:
                edges[(layer_of[dep], layer_of[k])] += 1
                model_edges.append({"from": models[dep]["name"], "to": n["name"]})
            elif dep.startswith("source."):
                edges[("sources", layer_of[k])] += 1
            elif dep.startswith("seed."):
                edges[("seeds", layer_of[k])] += 1

    def anchor(unique_id: str) -> str:
        return f"#!/{unique_id.split('.')[0]}/{unique_id}"

    test_status = Counter(tests.values())
    by_layer = defaultdict(list)
    for k, n in sorted(models.items(), key=lambda kv: kv[1]["name"]):
        by_layer[layer_of[k]].append({
            "name": n["name"],
            "materialized": n["config"]["materialized"],
            "contract": bool(n["config"].get("contract", {}).get("enforced")),
            "status": results.get(k),
            "docs_anchor": anchor(k),
        })

    generated = run_results["metadata"]["generated_at"]
    return {
        "generated_at_utc": generated,
        "dbt_version": run_results["metadata"]["dbt_version"],
        "elapsed_seconds": round(run_results.get("elapsed_time", 0), 1),
        "models_total": len(models),
        "models_by_layer": {layer: len(by_layer.get(layer, [])) for layer in layer_order},
        "snapshots": sum(1 for n in nodes.values() if n["resource_type"] == "snapshot"),
        "seeds": sum(1 for n in nodes.values() if n["resource_type"] == "seed"),
        "tests_total": len(tests),
        "tests_passed": test_status.get("pass", 0),
        "tests_warned": test_status.get("warn", 0),
        "tests_failed": test_status.get("fail", 0) + test_status.get("error", 0),
        "tests_skipped": test_status.get("skipped", 0),
        "warned_tests": sorted(manifest["nodes"][k]["name"] for k, v in tests.items() if v == "warn"),
        "contracted_models": sorted(n["name"] for n in models.values() if n["config"].get("contract", {}).get("enforced")),
        "incremental_models": sorted(n["name"] for n in models.values() if n["config"]["materialized"] == "incremental"),
        "external_models": sorted(n["name"] for n in models.values() if n["config"]["materialized"] == "external"),
        "sources": len(manifest["sources"]),
        "exposures": len(manifest["exposures"]),
        "semantic_models": len(manifest.get("semantic_models", {})),
        "metrics": len(manifest.get("metrics", {})),
        "layer_edges": [{"from": a, "to": b, "count": c} for (a, b), c in sorted(edges.items())],
        "model_edges": sorted(model_edges, key=lambda e: (e["from"], e["to"])),
        "docs": {
            "index": "dbt/index.html",
            "overview_anchor": "#!/overview",
            "lineage_anchor": "#!/overview?g_v=1",
            "layers": {layer: [m["docs_anchor"] for m in by_layer.get(layer, [])] for layer in layer_order},
        },
        "models": dict(by_layer),
    }


# ------------------------------------------------------------------ data blocks

def main() -> None:
    con = duckdb.connect(DB, read_only=True)
    cfg = yaml.safe_load((ROOT / "dbt_project.yml").read_text())["vars"]

    window = one(con, "select min(date_day) as first, max(date_day) as last, count(*) as n from marts.dim_dates")
    pulled = one(con, "select max(loaded_at) as at from audit.load_log")
    counts = one(con, """
        select
            (select count(*) from raw.lamp_subway_on_time) as lamp_raw_rows,
            (select count(*) from marts.fct_trip_stop_events) as trip_stop_events,
            (select count(*) from marts.fct_trips) as trips,
            (select count(*) from marts.dim_stations) as stations,
            (select count(*) from raw.mbta_gated_station_entries) as gated_entry_rows,
            (select count(*) from raw.mbta_monthly_ridership) as monthly_ridership_rows
    """)
    rider_basis = one(con, "select min(rider_basis_start_date) as start, max(rider_basis_end_date) as end from marts.mart_station_reliability")

    # Systemwide tiles: pooled from the daily line mart (weights = the denominators).
    sysw = one(con, """
        select
            sum(late_trip_share * trips_compared) / sum(trips_compared) as late_trip_share,
            sum(avg_trip_excess_seconds * trips_compared) / sum(trips_compared) as avg_trip_excess_seconds,
            sum(long_gap_share * headway_observations) / sum(headway_observations) as long_gap_share,
            sum(headway_adherence_share * headway_observations) / sum(headway_observations) as headway_adherence_share,
            sum(trips) as trips, sum(trips_compared) as trips_compared, sum(headway_observations) as headway_observations,
            sum(trip_excess_seconds_sum) / sum(trip_scheduled_seconds_sum) as excess_share_of_scheduled,
            sum(trip_scheduled_seconds_sum) / sum(trips_compared) as avg_scheduled_trip_seconds
        from marts.mart_line_daily_reliability
    """)
    exposure = one(con, """
        select
            sum(weekday_entries_in_long_gaps) as weekday_entries_in_long_gaps,
            sum(weekday_gated_entries) as weekday_gated_entries,
            sum(est_daily_entries_in_long_gaps) as all_days_entries_in_long_gaps,
            sum(avg_daily_gated_entries) as all_days_gated_entries,
            count(*) filter (where has_gated_entries) as stations_with_gates,
            count(*) as stations
        from marts.mart_station_overview
    """)
    line_totals = rows(con, """
        select
            m.route_id, r.display_name, r.line_id, r.route_color_hex, r.display_order,
            sum(m.trips) as trips,
            sum(m.trips_compared) as trips_compared,
            sum(m.late_trip_share * m.trips_compared) / sum(m.trips_compared) as late_trip_share,
            sum(m.avg_trip_excess_seconds * m.trips_compared) / sum(m.trips_compared) as avg_trip_excess_seconds,
            sum(m.long_gap_share * m.headway_observations) / sum(m.headway_observations) as long_gap_share,
            sum(m.headway_adherence_share * m.headway_observations) / sum(m.headway_observations) as headway_adherence_share,
            sum(m.bunched_share * m.headway_observations) / sum(m.headway_observations) as bunched_share,
            sum(m.trip_excess_seconds_sum) / sum(m.trip_scheduled_seconds_sum) as excess_share_of_scheduled,
            sum(m.trip_scheduled_seconds_sum) / sum(m.trips_compared) as avg_scheduled_trip_seconds
        from marts.mart_line_daily_reliability m join marts.dim_routes r using (route_id)
        group by all order by r.display_order
    """)
    worst = max(line_totals, key=lambda x: x["late_trip_share"])
    worst_gap = max(line_totals, key=lambda x: x["long_gap_share"])
    worst_rel = max(line_totals, key=lambda x: x["excess_share_of_scheduled"])
    last = window["last"]
    today = dt.datetime.now(BOSTON).date()
    lag_days = (today - last).days

    tiles = [
        {
            "id": "late_trip_share",
            "label": "Trips 5+ min behind schedule",
            "value": r(sysw["late_trip_share"]),
            "display": pct(sysw["late_trip_share"]),
            "explainer": f"Of {sysw['trips_compared']:,} subway train runs compared to the schedule, this share took more than 5 minutes longer than scheduled between their first and last compared stops.",
        },
        {
            "id": "avg_trip_excess_seconds",
            "label": "Average time over schedule per trip",
            "value": r(sysw["avg_trip_excess_seconds"], 1),
            "display": f"{sysw['avg_trip_excess_seconds']:+.0f} s",
            "share_of_scheduled": r(sysw["excess_share_of_scheduled"]),
            "explainer": f"Per train run, actual minus scheduled time summed over its compared stops, averaged over all compared runs. That is {pct(sysw['excess_share_of_scheduled'])} of an average {sysw['avg_scheduled_trip_seconds'] / 60:.0f}-minute scheduled run. Small on average; the late tail is what riders feel.",
        },
        {
            "id": "long_gap_share",
            "label": "Waits over 1.5x the scheduled gap",
            "value": r(sysw["long_gap_share"]),
            "display": pct(sysw["long_gap_share"]),
            "explainer": f"Share of {sysw['headway_observations']:,} train departures from stations where the gap since the previous train on the line was more than 1.5 times the scheduled gap.",
        },
        {
            "id": "weekday_entries_in_long_gaps",
            "label": "Weekday gate entries during long gaps",
            "value": round(exposure["weekday_entries_in_long_gaps"]),
            "display": f"~{exposure['weekday_entries_in_long_gaps'] / 1000:.1f}k",
            "share_of_entries": r(exposure["weekday_entries_in_long_gaps"] / exposure["weekday_gated_entries"]),
            "weekday_gated_entries": round(exposure["weekday_gated_entries"]),
            "all_days_value": round(exposure["all_days_entries_in_long_gaps"]),
            "explainer": f"On an average weekday, about {exposure['weekday_entries_in_long_gaps']:,.0f} of {exposure['weekday_gated_entries']:,.0f} fare-gate entries ({pct(exposure['weekday_entries_in_long_gaps'] / exposure['weekday_gated_entries'])}) are made at a station, line and time of day while trains are running a long gap, estimated from the long-gap share. Entries, not people; only the {exposure['stations_with_gates']} gated stations are counted.",
        },
        {
            "id": "worst_line",
            "label": "Line most often behind schedule",
            "value": worst["route_id"],
            "display": worst["display_name"],
            "metric_value": r(worst["late_trip_share"]),
            "metric_display": pct(worst["late_trip_share"]),
            "explainer": f"{worst['display_name']} had the highest share of trips 5+ minutes late ({pct(worst['late_trip_share'])}). Relative to scheduled run time, {worst_rel['display_name']} ran furthest over ({pct(worst_rel['excess_share_of_scheduled'])}). {worst_gap['display_name']} had the most long gaps ({pct(worst_gap['long_gap_share'])}).",
        },
        {
            "id": "freshness",
            "label": "Latest service day loaded",
            "value": last.isoformat(),
            "display": last.strftime("%b %-d, %Y"),
            "days_behind": lag_days,
            "explainer": f"MBTA publishes each day's subway data the next day. Data here runs through {last.strftime('%A, %B %-d')}" + (" (yesterday)." if lag_days == 1 else f" ({lag_days} days ago)."),
        },
    ]

    daily = rows(con, """
        select route_id, service_date, trips, trips_compared, late_trip_share, avg_trip_excess_seconds,
               long_gap_share, headway_adherence_share, median_excess_travel_seconds
        from marts.mart_line_daily_reliability order by route_id, service_date
    """)
    by_route = defaultdict(list)
    for d in daily:
        by_route[d["route_id"]].append({
            "date": d["service_date"].isoformat(),
            "trips": d["trips"],
            "trips_compared": d["trips_compared"],
            "late_trip_share": r(d["late_trip_share"]),
            "avg_trip_excess_seconds": r(d["avg_trip_excess_seconds"], 1),
            "long_gap_share": r(d["long_gap_share"]),
            "headway_adherence_share": r(d["headway_adherence_share"]),
        })
    lines = [{
        "route_id": t["route_id"], "line_id": t["line_id"], "display_name": t["display_name"],
        "color": t["route_color_hex"], "trips": t["trips"], "trips_compared": t["trips_compared"],
        "excess_share_of_scheduled": r(t["excess_share_of_scheduled"]),
        "avg_scheduled_trip_minutes": r(t["avg_scheduled_trip_seconds"] / 60, 1),
        "late_trip_share": r(t["late_trip_share"]), "avg_trip_excess_seconds": r(t["avg_trip_excess_seconds"], 1),
        "long_gap_share": r(t["long_gap_share"]), "bunched_share": r(t["bunched_share"]),
        "headway_adherence_share": r(t["headway_adherence_share"]),
        "daily": by_route[t["route_id"]],
    } for t in line_totals]

    worst_stations = rows(con, """
        select station_id, station_name, line_ids, weekday_gated_entries, weekday_entries_in_long_gaps,
               rider_weighted_long_gap_share, rider_weighted_excess_seconds, headway_observations
        from marts.mart_station_overview
        where has_rider_data
        order by weekday_entries_in_long_gaps desc
        limit 8
    """)
    worst_stations = [{
        "station_id": s["station_id"], "station_name": s["station_name"], "lines": s["line_ids"].split(","),
        "weekday_gated_entries": round(s["weekday_gated_entries"]),
        "weekday_entries_in_long_gaps": round(s["weekday_entries_in_long_gaps"]),
        "rider_weighted_long_gap_share": r(s["rider_weighted_long_gap_share"]),
        "rider_weighted_excess_seconds": r(s["rider_weighted_excess_seconds"], 1),
        "explainer": f"On an average weekday, about {round(s['weekday_entries_in_long_gaps']):,} of ~{round(s['weekday_gated_entries']):,} gate entries here happen while trains are running a long gap.",
    } for s in worst_stations]

    # data coverage (mart_data_coverage, mart_station_overview)
    cov_routes = rows(con, """
        select c.*, r.display_name from marts.mart_data_coverage c join marts.dim_routes r using (route_id)
        order by r.display_order
    """)
    ungated = rows(con, """
        select station_id, station_name, line_ids from marts.mart_station_overview
        where not has_gated_entries order by line_ids, station_id
    """)
    green_st = one(con, """
        select count(*) as stations, count(*) filter (where not has_gated_entries) as ungated
        from marts.mart_station_overview where list_contains(string_split(line_ids, ','), 'Green')
    """)
    tot = lambda key, rs: sum(x[key] for x in rs)
    green = [x for x in cov_routes if x["line_id"] == "Green"]
    n_events = tot("trip_stop_events", cov_routes)
    data_coverage = {
        "definitions": {
            "no_scheduled_travel": "LAMP has no scheduled run time from the previous stop, or it is zero or less (includes the first stop of every trip and added trips).",
            "no_scheduled_headway": "LAMP has no scheduled gap since the previous train, or it is zero.",
            "ungated_station": "Station not in MBTA gated-entry data, so it has no rider weight.",
        },
        "system": {
            "trip_stop_events": n_events,
            "without_scheduled_travel": tot("events_without_scheduled_travel", cov_routes),
            "without_scheduled_headway": tot("events_without_scheduled_headway", cov_routes),
            "without_any_schedule": tot("events_without_any_schedule", cov_routes),
            "share_without_scheduled_travel": r(tot("events_without_scheduled_travel", cov_routes) / n_events),
            "share_without_scheduled_headway": r(tot("events_without_scheduled_headway", cov_routes) / n_events),
            "share_without_any_schedule": r(tot("events_without_any_schedule", cov_routes) / n_events),
            "events_at_ungated_stations": tot("events_at_ungated_stations", cov_routes),
            "share_events_at_ungated_stations": r(tot("events_at_ungated_stations", cov_routes) / n_events),
        },
        "by_route": [{
            "route_id": x["route_id"], "display_name": x["display_name"],
            "trip_stop_events": x["trip_stop_events"],
            "without_scheduled_travel": x["events_without_scheduled_travel"],
            "share_without_scheduled_travel": r(x["share_without_scheduled_travel"]),
            "without_scheduled_headway": x["events_without_scheduled_headway"],
            "share_without_scheduled_headway": r(x["share_without_scheduled_headway"]),
            "without_any_schedule": x["events_without_any_schedule"],
            "share_without_any_schedule": r(x["share_without_any_schedule"]),
            "stations_served": x["stations_served"],
            "stations_without_gated_entries": x["stations_without_gated_entries"],
            "share_events_at_ungated_stations": r(x["share_events_at_ungated_stations"]),
        } for x in cov_routes],
        "stations_without_gated_entries": {
            "count": len(ungated),
            "of_stations": one(con, "select count(*) as n from marts.mart_station_overview")["n"],
            "station_ids": [s["station_id"] for s in ungated],
            "by_line": {ln: [s["station_id"] for s in ungated if ln in s["line_ids"].split(",")]
                        for ln in sorted({l for s in ungated for l in s["line_ids"].split(",")})},
        },
        "green_line_surface": {
            "stations": green_st["stations"],
            "ungated_stations": green_st["ungated"],
            "share_of_stations": r(green_st["ungated"] / green_st["stations"]),
            "share_of_trip_stop_events": r(tot("events_at_ungated_stations", green) / tot("trip_stop_events", green)),
            "note": "Approximated as Green Line stations without gated-entry data. All are surface stops except Symphony (underground, no gate data) and Longwood (gated rows lack a stop id).",
        },
    }

    min_trips = 200
    worst_periods = rows(con, f"""
        select p.route_id, r.display_name, p.service_period_id, sp.service_period_name, sp.clock_range,
               p.trips_compared, p.late_trip_share, p.long_gap_share, p.avg_trip_excess_seconds
        from marts.mart_period_reliability p
        join marts.dim_routes r using (route_id)
        join marts.dim_service_periods sp using (service_period_id)
        where p.day_type = 'weekday' and p.trips_compared >= {min_trips}
        order by p.late_trip_share desc
        limit 8
    """)
    worst_periods = [{
        "route_id": p["route_id"], "display_name": p["display_name"], "service_period_id": p["service_period_id"],
        "service_period_name": p["service_period_name"], "clock_range": p["clock_range"], "day_type": "weekday",
        "trips_compared": p["trips_compared"], "late_trip_share": r(p["late_trip_share"]),
        "long_gap_share": r(p["long_gap_share"]), "avg_trip_excess_seconds": r(p["avg_trip_excess_seconds"], 1),
    } for p in worst_periods]

    # ---------------------------------------------------------------- map
    map_stations = rows(con, """
        select station_id, station_name, latitude, longitude, route_ids, line_ids, has_rider_data,
               avg_daily_gated_entries, map_excess_seconds, map_long_gap_share,
               rider_weighted_excess_seconds, rider_weighted_long_gap_share, est_daily_entries_in_long_gaps,
               weekday_gated_entries, weekday_entries_in_long_gaps
        from marts.mart_station_overview order by station_id
    """)
    stops = rows(con, """
        select s.route_id, s.branch_route_id, s.direction_id, s.direction_name, s.direction_destination,
               s.route_pattern_name, s.stop_order, s.station_id, s.route_color_hex, r.display_name, r.branch_name
        from marts.mart_line_stop_sequence s join marts.dim_routes r using (route_id)
        order by r.display_order, s.branch_route_id, s.direction_id, s.stop_order
    """)
    map_lines = {}
    for s in stops:
        key = (s["branch_route_id"], s["direction_id"])
        if key not in map_lines:
            branch = {"Red-A": "Ashmont", "Red-B": "Braintree"}.get(s["branch_route_id"], s["branch_name"])
            map_lines[key] = {
                "route_id": s["route_id"], "branch_route_id": s["branch_route_id"],
                "display_name": s["display_name"], "branch": branch,
                "direction_id": s["direction_id"], "direction": s["direction_name"],
                "destination": s["direction_destination"], "pattern": s["route_pattern_name"],
                "color": s["route_color_hex"], "stops": [],
            }
        map_lines[key]["stops"].append(s["station_id"])
    # track geometry (mart_line_shapes): ordered [lon, lat] points per branch and direction
    for pt in rows(con, """
        select branch_route_id, direction_id, longitude, latitude
        from marts.mart_line_shapes order by branch_route_id, direction_id, point_order
    """):
        key = (pt["branch_route_id"], pt["direction_id"])
        if key in map_lines:
            map_lines[key].setdefault("shape", []).append([pt["longitude"], pt["latitude"]])
    periods = rows(con, """
        select sp.service_period_id, sp.service_period_name, sp.clock_range, sp.start_minute, sp.end_minute, sp.sort_order,
               sum(p.late_trip_share * p.trips_compared) / nullif(sum(p.trips_compared), 0) as late_trip_share,
               sum(p.long_gap_share * p.headway_observations) / nullif(sum(p.headway_observations), 0) as long_gap_share,
               sum(p.trips_compared) as trips_compared
        from marts.dim_service_periods sp
        left join marts.mart_period_reliability p on p.service_period_id = sp.service_period_id and p.day_type = 'weekday'
        group by all order by sp.sort_order
    """)
    coverage = one(con, """
        select
            count(*) as stations,
            count(*) filter (where latitude is not null and longitude is not null) as with_coordinates,
            count(*) filter (where has_rider_data) as with_rider_data,
            count(*) filter (where trip_stop_events > 0) as with_lamp_events
        from marts.mart_station_overview
    """)
    expected_branches = ["Red-A", "Red-B", "Mattapan", "Orange", "Green-B", "Green-C", "Green-D", "Green-E", "Blue"]
    present = sorted({k[0] for k in map_lines})
    map_block = {
        "crs": "WGS84 (EPSG:4326). Stations from GTFS stops.txt, track shapes from GTFS shapes.txt as [lon, lat].",
        "gtfs_as_of": stops[0]["route_pattern_name"] and str(one(con, "select max(gtfs_as_of_date) as d from marts.mart_line_stop_sequence")["d"]),
        "shading_note": "map_* values are rider-weighted where the station has fare gates, otherwise weighted by train arrivals (has_rider_data = false).",
        "stations": [{
            "station_id": s["station_id"], "name": s["station_name"],
            "lat": s["latitude"], "lon": s["longitude"],
            "route_ids": s["route_ids"].split(","), "line_ids": s["line_ids"].split(","),
            "has_rider_data": s["has_rider_data"],
            "avg_daily_gated_entries": None if s["avg_daily_gated_entries"] is None else round(s["avg_daily_gated_entries"]),
            "excess_seconds": r(s["map_excess_seconds"], 1),
            "long_gap_share": r(s["map_long_gap_share"]),
            "rider_weighted_excess_seconds": r(s["rider_weighted_excess_seconds"], 1),
            "rider_weighted_long_gap_share": r(s["rider_weighted_long_gap_share"]),
            "est_daily_entries_in_long_gaps": None if s["est_daily_entries_in_long_gaps"] is None else round(s["est_daily_entries_in_long_gaps"]),
            "weekday_gated_entries": None if s["weekday_gated_entries"] is None else round(s["weekday_gated_entries"]),
            "weekday_entries_in_long_gaps": None if s["weekday_entries_in_long_gaps"] is None else round(s["weekday_entries_in_long_gaps"]),
        } for s in map_stations],
        "lines": list(map_lines.values()),
        "periods": [{
            "service_period_id": p["service_period_id"], "name": p["service_period_name"], "clock_range": p["clock_range"],
            "start_minute": p["start_minute"], "end_minute": p["end_minute"], "sort_order": p["sort_order"],
            "weekday_late_trip_share": r(p["late_trip_share"]), "weekday_long_gap_share": r(p["long_gap_share"]),
            "weekday_trips_compared": p["trips_compared"],
        } for p in periods],
        "coverage": {
            **coverage,
            "branches_expected": expected_branches,
            "branches_present": present,
            "branches_missing": sorted(set(expected_branches) - set(present)),
        },
    }

    files = []
    for f in sorted(OUT.glob("*.parquet")):
        n = con.execute(f"select count(*) from read_parquet('{f.as_posix()}')").fetchone()[0]
        files.append({"file": f.name, "bytes": f.stat().st_size, "rows": n})

    board = {
        "meta": {
            "title": "Where the subway falls behind its schedule",
            "question": "Which lines, stations and times of day run furthest behind schedule or leave the longest gaps between trains, and how many riders does that touch?",
            "sources": SOURCES,
            "pulled_at_utc": pulled["at"].strftime("%Y-%m-%dT%H:%M:%SZ") if pulled["at"] else None,
            "service_date_window": {"first": window["first"].isoformat(), "last": last.isoformat(), "days": window["n"]},
            "rider_basis_window": {"first": rider_basis["start"].isoformat(), "last": rider_basis["end"].isoformat()},
            "row_counts": counts,
            "thresholds": {
                "late_trip_seconds": cfg["late_trip_seconds"],
                "long_gap_ratio": cfg["long_gap_ratio"],
                "bunched_ratio": cfg["bunched_ratio"],
                "travel_outlier_seconds": cfg["travel_outlier_seconds"],
            },
            "method": "Actual arrival-to-arrival times between stops are compared to the published schedule for every subway train, and actual gaps between trains to scheduled gaps. Stations are weighted by fare-gate entries for the same time of day.",
            "disclaimer": "Public MBTA data. Live positions from the MBTA V3 API. Not affiliated with the MBTA.",
            "attribution": "Data provided by MassDOT / MBTA under the MassDOT Developers License Agreement.",
        },
        "tiles": tiles,
        "lines": lines,
        "worst_stations": worst_stations,
        "worst_periods": worst_periods,
        "worst_periods_rule": f"Weekday line x service period cells with at least {min_trips} compared trips, ranked by share of trips 5+ minutes late.",
        "map": map_block,
        "files": files,
        "build": build_block(),
        "coverage": data_coverage,
        "glossary": GLOSSARY,
    }
    OUT.mkdir(exist_ok=True)
    (OUT / "board_data.json").write_text(json.dumps(board, separators=(",", ":"), default=str))
    print(f"wrote {OUT / 'board_data.json'} ({(OUT / 'board_data.json').stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
