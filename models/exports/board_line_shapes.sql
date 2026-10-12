{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_shapes.parquet'
    )
}}
-- Board file: track geometry per branch and direction (mart_line_shapes), then Commuter Rail
-- (mart_cr_route_shapes); ordered points. mode: subway or commuter_rail.

select
    route_id,
    branch_route_id,
    direction_id,
    point_order,
    longitude,
    latitude,
    route_color_hex,
    'subway' as mode
from {{ ref('mart_line_shapes') }}

union all

select
    route_id,
    branch_route_id,
    direction_id,
    point_order,
    longitude,
    latitude,
    route_color_hex,
    'commuter_rail' as mode
from {{ ref('mart_cr_route_shapes') }}
order by mode desc, route_id asc, branch_route_id asc, direction_id asc, point_order asc
