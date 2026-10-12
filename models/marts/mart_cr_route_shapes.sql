-- Grain: one row per Commuter Rail pattern branch, direction and point along the track of the
-- canonical route pattern (GTFS version active on gtfs_as_of_date()). Shape = GTFS shapes.txt of
-- the representative trip; points rounded to 5 decimals (about 1 m) with consecutive duplicates
-- dropped, as for the subway (int_line_shapes).

with as_of as (

    select {{ gtfs_as_of_date() }} as as_of_date

),

patterns as (

    select distinct
        stops.route_id,
        stops.branch_route_id,
        stops.direction_id,
        stops.route_pattern_id
    from {{ ref('mart_cr_route_stops') }} as stops

),

pattern_trips as (

    select
        rp.route_pattern_id,
        rp.representative_trip_id
    from {{ ref('stg_gtfs__route_patterns') }} as rp
    cross join as_of
    where rp.is_canonical and as_of.as_of_date between rp.valid_from_date and rp.valid_to_date

),

trips as (

    select
        t.trip_id,
        t.shape_id
    from {{ ref('stg_gtfs__cr_trips') }} as t
    cross join as_of
    where as_of.as_of_date between t.valid_from_date and t.valid_to_date

),

shapes as (

    select
        s.shape_id,
        s.shape_point_sequence,
        round(s.longitude, 5) as longitude,
        round(s.latitude, 5) as latitude
    from {{ ref('stg_gtfs__cr_shapes') }} as s
    cross join as_of
    where as_of.as_of_date between s.valid_from_date and s.valid_to_date

),

points as (

    select
        patterns.route_id,
        patterns.branch_route_id,
        patterns.direction_id,
        trips.shape_id,
        shapes.shape_point_sequence,
        shapes.longitude,
        shapes.latitude,
        lag(shapes.longitude) over shape_order as prev_longitude,
        lag(shapes.latitude) over shape_order as prev_latitude
    from patterns
    inner join pattern_trips on patterns.route_pattern_id = pattern_trips.route_pattern_id
    inner join trips on pattern_trips.representative_trip_id = trips.trip_id
    inner join shapes on trips.shape_id = shapes.shape_id
    window shape_order as (
        partition by patterns.branch_route_id, patterns.direction_id
        order by shapes.shape_point_sequence
    )

),

kept as (

    select
        *,
        row_number() over (partition by branch_route_id, direction_id order by shape_point_sequence)
            as point_order
    from points
    where
        prev_longitude is null
        or longitude != prev_longitude
        or latitude != prev_latitude

)

select
    {{ dbt_utils.generate_surrogate_key(['kept.branch_route_id', 'kept.direction_id', 'kept.point_order']) }}
        as cr_shape_point_key,
    cast(kept.route_id as varchar) as route_id,
    cast(kept.branch_route_id as varchar) as branch_route_id,
    cast(kept.direction_id as integer) as direction_id,
    cast(kept.shape_id as varchar) as shape_id,
    cast(kept.point_order as integer) as point_order,
    cast(kept.longitude as double) as longitude,
    cast(kept.latitude as double) as latitude,
    cast(routes.route_color_hex as varchar) as route_color_hex
from kept
left join {{ ref('dim_cr_routes') }} as routes on kept.route_id = routes.route_id
