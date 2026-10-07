-- Grain: one row per branch, direction and stop position on the canonical route pattern.
-- Ordered station list per line branch for drawing the network; coordinates and the official
-- route color are joined from dim_stations and dim_routes.

with seq as (

    select * from {{ ref('int_line_stop_sequence') }}

),

directions as (

    -- direction labels as LAMP publishes them (from GTFS directions.txt)
    select
        route_id,
        direction_id,
        mode(direction) as direction_name,
        mode(direction_destination) as direction_destination
    from {{ ref('stg_lamp__subway_trip_stops') }}
    group by route_id, direction_id

)

select
    cast(seq.line_stop_key as varchar) as line_stop_key,
    cast(seq.route_id as varchar) as route_id,
    cast(seq.branch_route_id as varchar) as branch_route_id,
    cast(seq.direction_id as integer) as direction_id,
    cast(directions.direction_name as varchar) as direction_name,
    cast(directions.direction_destination as varchar) as direction_destination,
    cast(seq.route_pattern_name as varchar) as route_pattern_name,
    cast(seq.route_pattern_id as varchar) as route_pattern_id,
    cast(seq.stop_order as integer) as stop_order,
    cast(count(*) over (partition by seq.branch_route_id, seq.direction_id) as integer) as stops_on_pattern,
    cast(seq.station_id as varchar) as station_id,
    cast(stations.station_name as varchar) as station_name,
    cast(stations.latitude as double) as latitude,
    cast(stations.longitude as double) as longitude,
    cast(routes.route_color_hex as varchar) as route_color_hex,
    cast(seq.gtfs_as_of_date as date) as gtfs_as_of_date
from seq
left join directions
    on seq.route_id = directions.route_id and seq.direction_id = directions.direction_id
left join {{ ref('dim_stations') }} as stations
    on seq.station_id = stations.station_id
left join {{ ref('dim_routes') }} as routes
    on seq.route_id = routes.route_id
