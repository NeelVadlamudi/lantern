{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/freedom_trail.parquet'
    )
}}
-- Board file: Freedom Trail sites as optional map landmarks, each with its nearest subway or
-- Commuter Rail station (mart_freedom_trail_nearest_stops). Grain: one row per site, in trail order.
-- distance_m is exact straight-line metres; distance_label rounds it to whole metres for display.
-- walk_label is an estimate: format_duration of est_walk_seconds (straight-line distance at
-- walk_speed_m_per_s), not a measured or routed walking time.

select
    site_order,
    site_name,
    latitude,
    longitude,
    nearest_stop_id,
    nearest_stop_name,
    string_split(nearest_stop_route_ids, ',') as nearest_stop_route_ids,
    string_split(nearest_stop_line_ids, ',') as nearest_stop_line_ids,
    string_split(nearest_stop_modes, ',') as nearest_stop_modes,
    distance_m,
    cast(round(distance_m, 0) as bigint) || ' m' as distance_label,
    est_walk_seconds,
    {{ format_duration('est_walk_seconds') }} as walk_label,
    walk_speed_m_per_s,
    'Estimate: straight-line distance at ' || walk_speed_m_per_s || ' m/s walking speed' as walk_basis,
    source_url,
    note
from {{ ref('mart_freedom_trail_nearest_stops') }}
order by site_order
