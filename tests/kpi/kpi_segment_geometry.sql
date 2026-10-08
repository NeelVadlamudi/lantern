-- Every segment has a geometry of at least two [lon, lat] points inside the Boston area, and
-- the first and last points are within 500 m of the two stations (shape slices start and end at
-- the shape points nearest the stations).
with segments as (
    select
        segments.*,
        from_station.latitude as from_lat,
        from_station.longitude as from_lon,
        to_station.latitude as to_lat,
        to_station.longitude as to_lon
    from {{ ref('dim_segments') }} as segments
    inner join {{ ref('dim_stations') }} as from_station on segments.from_station_id = from_station.station_id
    inner join {{ ref('dim_stations') }} as to_station on segments.to_station_id = to_station.station_id
)

select
    segment_id,
    segment_name,
    len(geometry) as points
from segments
where
    len(geometry) < 2
    or list_bool_or(list_transform(geometry, p -> p[1] not between -71.4 and -70.8 or p[2] not between 42.1 and 42.6))
    or 111000 * sqrt(power(geometry[1][2] - from_lat, 2) + power((geometry[1][1] - from_lon) * 0.74, 2)) > 500
    or 111000 * sqrt(power(geometry[-1][2] - to_lat, 2) + power((geometry[-1][1] - to_lon) * 0.74, 2)) > 500
