{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/routes.parquet'
    )
}}
-- Board file: the eight subway routes with V3 route ids, display names and official colors
-- (dim_routes), then the 13 Commuter Rail routes (dim_cr_routes). mode: subway or commuter_rail.

select
    route_id,
    line_id,
    display_name,
    transit_mode,
    'subway' as mode,
    route_color_hex,
    route_text_color_hex,
    display_order
from {{ ref('dim_routes') }}

union all

select
    route_id,
    null as line_id,
    display_name,
    transit_mode,
    mode,
    route_color_hex,
    route_text_color_hex,
    100 + display_order as display_order
from {{ ref('dim_cr_routes') }}
order by display_order
