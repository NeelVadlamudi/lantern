-- Grain: one row per track segment: a pair of consecutive stations on a line's canonical
-- route pattern, in one direction (line_id, direction_id, from_station_id, to_station_id).
-- Branches that share track (the Red Line trunk, the Green Line central subway) share
-- segments, so each stretch of track is counted once; branch_route_ids lists the branches
-- that run over it.
-- Geometry: the GTFS track shape of one branch over the segment (shape points between the
-- points nearest each station, as [lon, lat]). If the shape does not run from one station to
-- the other in order, a straight line between the two stations is used instead
-- (geometry_source says which).

with stop_sequence as (

    select
        *,
        case when route_id like 'Green-%' then 'Green' else route_id end as line_id
    from {{ ref('int_line_stop_sequence') }}

),

pairs as (

    select
        line_id,
        route_id,
        branch_route_id,
        direction_id,
        stop_order as from_stop_order,
        station_id as from_station_id,
        lead(station_id) over (partition by branch_route_id, direction_id order by stop_order) as to_station_id
    from stop_sequence

),

segments as (

    select
        line_id,
        direction_id,
        from_station_id,
        to_station_id,
        list(distinct branch_route_id order by branch_route_id) as branch_route_ids,
        min(branch_route_id) as geometry_branch_route_id,
        arg_min(route_id, branch_route_id) as route_id,
        min(from_stop_order) as from_stop_order
    from pairs
    where to_station_id is not null
    group by line_id, direction_id, from_station_id, to_station_id

),

stations as (

    select
        station_id,
        station_name,
        latitude,
        longitude
    from {{ ref('int_gtfs_stations_as_of') }}

),

shape_points as (

    select
        branch_route_id,
        direction_id,
        point_order,
        longitude,
        latitude
    from {{ ref('int_line_shapes') }}

),

nearest as (

    select
        segments.line_id,
        segments.direction_id,
        segments.from_station_id,
        segments.to_station_id,
        arg_min(
            shape_points.point_order,
            power(shape_points.latitude - from_station.latitude, 2)
            + power(shape_points.longitude - from_station.longitude, 2)
        ) as from_point_order,
        arg_min(
            shape_points.point_order,
            power(shape_points.latitude - to_station.latitude, 2)
            + power(shape_points.longitude - to_station.longitude, 2)
        ) as to_point_order
    from segments
    inner join stations as from_station on segments.from_station_id = from_station.station_id
    inner join stations as to_station on segments.to_station_id = to_station.station_id
    inner join shape_points
        on
            segments.geometry_branch_route_id = shape_points.branch_route_id
            and segments.direction_id = shape_points.direction_id
    group by all

),

shape_geometry as (

    select
        nearest.line_id,
        nearest.direction_id,
        nearest.from_station_id,
        nearest.to_station_id,
        list(
            [shape_points.longitude, shape_points.latitude] order by shape_points.point_order
        ) as geometry  -- noqa: RF04
    from nearest
    inner join segments
        on
            nearest.line_id = segments.line_id
            and nearest.direction_id = segments.direction_id
            and nearest.from_station_id = segments.from_station_id
            and nearest.to_station_id = segments.to_station_id
    inner join shape_points
        on
            segments.geometry_branch_route_id = shape_points.branch_route_id
            and segments.direction_id = shape_points.direction_id
            and shape_points.point_order between nearest.from_point_order and nearest.to_point_order
    where nearest.to_point_order > nearest.from_point_order
    group by all

)

select
    {{ dbt_utils.generate_surrogate_key([
        'segments.line_id', 'segments.direction_id', 'segments.from_station_id', 'segments.to_station_id'
    ]) }} as segment_id,
    cast(segments.line_id as varchar) as line_id,
    cast(segments.route_id as varchar) as route_id,
    cast(segments.direction_id as integer) as direction_id,
    cast(segments.from_station_id as varchar) as from_station_id,
    cast(from_station.station_name as varchar) as from_station_name,
    cast(segments.to_station_id as varchar) as to_station_id,
    cast(to_station.station_name as varchar) as to_station_name,
    cast(from_station.station_name || ' to ' || to_station.station_name as varchar) as segment_name,
    cast(segments.branch_route_ids as varchar[]) as branch_route_ids,
    cast(segments.from_stop_order as integer) as from_stop_order,
    cast(
        coalesce(
            shape_geometry.geometry,
            [[from_station.longitude, from_station.latitude], [to_station.longitude, to_station.latitude]]
        ) as double[][]
    ) as geometry,  -- noqa: RF04
    cast(case when shape_geometry.geometry is null then 'straight_line' else 'shape' end as varchar)
        as geometry_source,
    cast(
        6371000 * 2 * asin(sqrt(
            power(sin(radians(to_station.latitude - from_station.latitude) / 2), 2)
            + cos(radians(from_station.latitude)) * cos(radians(to_station.latitude))
            * power(sin(radians(to_station.longitude - from_station.longitude) / 2), 2)
        )) as double
    ) as straight_line_meters
from segments
inner join stations as from_station on segments.from_station_id = from_station.station_id
inner join stations as to_station on segments.to_station_id = to_station.station_id
left join shape_geometry
    on
        segments.line_id = shape_geometry.line_id
        and segments.direction_id = shape_geometry.direction_id
        and segments.from_station_id = shape_geometry.from_station_id
        and segments.to_station_id = shape_geometry.to_station_id
