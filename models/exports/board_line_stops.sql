{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_stops.parquet'
    )
}}
-- Board file: ordered stations per branch and direction with coordinates and route color
-- (mart_line_stop_sequence), then Commuter Rail canonical patterns (mart_cr_route_stops; no
-- direction labels). mode: subway or commuter_rail.

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
    route_color_hex,
    'subway' as mode
from {{ ref('mart_line_stop_sequence') }}

union all

select
    route_id,
    branch_route_id,
    direction_id,
    null as direction_name,
    null as direction_destination,
    route_pattern_name,
    stop_order,
    stops_on_pattern,
    station_id,
    station_name,
    latitude,
    longitude,
    route_color_hex,
    'commuter_rail' as mode
from {{ ref('mart_cr_route_stops') }}
order by mode desc, route_id asc, branch_route_id asc, direction_id asc, stop_order asc
