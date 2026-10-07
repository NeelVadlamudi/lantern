{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/map_stations.parquet'
    )
}}
-- Board file: one row per station for the map (mart_station_overview).
-- station_id is the GTFS parent station id (place-*), the same id the MBTA V3 API uses for
-- stops, so live vehicle positions can be matched to it. route_ids is a list of V3 route ids.

select
    station_id,
    station_name,
    latitude,
    longitude,
    string_split(route_ids, ',') as route_ids,
    string_split(line_ids, ',') as line_ids,
    trip_stop_events,
    has_rider_data,
    round(avg_daily_gated_entries, 1) as avg_daily_gated_entries,
    round(map_excess_seconds, 1) as map_excess_seconds,
    round(map_long_gap_share, 4) as map_long_gap_share,
    round(rider_weighted_excess_seconds, 1) as rider_weighted_excess_seconds,
    round(rider_weighted_long_gap_share, 4) as rider_weighted_long_gap_share,
    round(est_daily_entries_in_long_gaps, 0) as est_daily_entries_in_long_gaps,
    round(weekday_gated_entries, 0) as weekday_gated_entries,
    round(weekday_entries_in_long_gaps, 0) as weekday_entries_in_long_gaps
from {{ ref('mart_station_overview') }}
order by station_id
