{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/routes.parquet'
    )
}}
-- Board file: the eight subway routes with V3 route ids, display names and official colors
-- (dim_routes).

select
    route_id,
    line_id,
    display_name,
    transit_mode,
    route_color_hex,
    route_text_color_hex,
    display_order
from {{ ref('dim_routes') }}
order by display_order
