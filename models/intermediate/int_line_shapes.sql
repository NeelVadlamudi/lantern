-- Grain: one row per branch, direction and point on the track shape of the canonical route
-- pattern (GTFS version active on gtfs_as_of_date()).
-- Shape = GTFS shapes.txt for the pattern's representative trip. Points are rounded to 5 decimals
-- (about 1 m) and consecutive duplicates dropped, which keeps the geometry while trimming size.

with as_of as (

    select {{ gtfs_as_of_date() }} as as_of_date

),

patterns as (

    -- one row per canonical pattern, with the branch id assigned in int_line_stop_sequence
    select distinct
        route_pattern_id,
        route_id,
        branch_route_id,
        direction_id
    from {{ ref('int_line_stop_sequence') }}

),

pattern_trips as (

    select
        rp.route_pattern_id,
        rp.representative_trip_id
    from {{ ref('stg_gtfs__route_patterns') }} as rp
    cross join as_of
    where
        rp.is_canonical
        and as_of.as_of_date between rp.valid_from_date and rp.valid_to_date

),

trips as (

    select
        t.trip_id,
        t.shape_id
    from {{ ref('stg_gtfs__trips') }} as t
    cross join as_of
    where as_of.as_of_date between t.valid_from_date and t.valid_to_date

),

shapes as (

    select
        s.shape_id,
        s.shape_point_sequence,
        round(s.longitude, 5) as longitude,
        round(s.latitude, 5) as latitude
    from {{ ref('stg_gtfs__shapes') }} as s
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
    inner join pattern_trips
        on patterns.route_pattern_id = pattern_trips.route_pattern_id
    inner join trips
        on pattern_trips.representative_trip_id = trips.trip_id
    inner join shapes
        on trips.shape_id = shapes.shape_id
    window shape_order as (
        partition by patterns.branch_route_id, patterns.direction_id
        order by shapes.shape_point_sequence
    )

)

select
    route_id,
    branch_route_id,
    direction_id,
    shape_id,
    cast(row_number() over (
        partition by branch_route_id, direction_id order by shape_point_sequence
    ) as integer) as point_order,
    longitude,
    latitude
from points
where
    prev_longitude is null
    or longitude != prev_longitude
    or latitude != prev_latitude
