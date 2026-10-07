-- Grain: one row per subway GTFS route (Red, Mattapan, Orange, Green-B/C/D/E, Blue),
-- attributes from the GTFS version active on the latest loaded service date.
-- route_color_hex is the MBTA's official color from GTFS routes.route_color.

with routes as (

    select r.*
    from {{ ref('stg_gtfs__routes') }} as r
    where {{ gtfs_as_of_date() }} between r.valid_from_date and r.valid_to_date

),

display as (

    select * from {{ ref('line_display') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['display.route_id']) }} as route_key,
    cast(display.route_id as varchar) as route_id,
    cast(display.line_id as varchar) as line_id,
    cast(routes.route_name as varchar) as route_name,
    cast(display.line_name as varchar) as line_name,
    cast(display.branch_name as varchar) as branch_name,
    cast(display.display_name as varchar) as display_name,
    cast(case routes.route_type when 0 then 'light rail' when 1 then 'heavy rail' end as varchar) as transit_mode,
    cast(routes.route_color_hex as varchar) as route_color_hex,
    cast(routes.route_text_color_hex as varchar) as route_text_color_hex,
    cast(display.display_order as integer) as display_order
from display
left join routes
    on display.route_id = routes.route_id
