{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_shapes.parquet'
    )
}}
-- Board file: track geometry per branch and direction (mart_line_shapes), ordered points.

select
    route_id,
    branch_route_id,
    direction_id,
    point_order,
    longitude,
    latitude,
    route_color_hex
from {{ ref('mart_line_shapes') }}
order by route_id, branch_route_id, direction_id, point_order
