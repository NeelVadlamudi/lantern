-- Grain: one row per Commuter Rail route: the GTFS routes with route_type 2 and a CR- route id
-- (13 routes), attributes from the GTFS version active on gtfs_as_of_date().
-- route_color_hex is the official color from GTFS routes.route_color. CapeFlyer (also route_type
-- 2, seasonal) is not a CR- route and is not included.

with routes as (

    select r.*
    from {{ ref('stg_gtfs__routes') }} as r
    where
        r.route_type = 2
        and r.route_id like 'CR-%'
        and {{ gtfs_as_of_date() }} between r.valid_from_date and r.valid_to_date

)

select
    {{ dbt_utils.generate_surrogate_key(['route_id']) }} as route_key,
    cast(route_id as varchar) as route_id,
    cast(route_name as varchar) as route_name,
    cast(route_name as varchar) as display_name,
    cast('commuter rail' as varchar) as transit_mode,
    cast('commuter_rail' as varchar) as mode,
    cast(route_color_hex as varchar) as route_color_hex,
    cast(route_text_color_hex as varchar) as route_text_color_hex,
    cast(route_sort_order as integer) as route_sort_order,
    cast(row_number() over (order by route_sort_order, route_id) as integer) as display_order
from routes
