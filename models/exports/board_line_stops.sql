{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_stops.parquet'
    )
}}
-- Board file: ordered stations per branch and direction with coordinates and route color
-- (mart_line_stop_sequence).

select
    route_id,
    branch_route_id,
    direction_id,
    direction_name,
    direction_destination,
    route_pattern_name,
    stop_order,
    stops_on_pattern,
    station_id,
    station_name,
    latitude,
    longitude,
    route_color_hex
from {{ ref('mart_line_stop_sequence') }}
order by route_id, branch_route_id, direction_id, stop_order
