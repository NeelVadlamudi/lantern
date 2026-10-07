-- Consecutive stations on a line pattern should be close together. A jump over 6 km means the
-- stop order or a coordinate is wrong (the longest real gap, JFK/UMass to North Quincy, is 5.4 km
-- in a straight line).
with seq as (
    select
        branch_route_id,
        direction_id,
        stop_order,
        station_id,
        latitude,
        longitude,
        lag(station_id) over w as prev_station_id,
        lag(latitude) over w as prev_latitude,
        lag(longitude) over w as prev_longitude
    from {{ ref('mart_line_stop_sequence') }}
    window w as (partition by branch_route_id, direction_id order by stop_order)
)

select
    *,
    6371 * 2 * asin(sqrt(
        pow(sin(radians(latitude - prev_latitude) / 2), 2)
        + cos(radians(prev_latitude)) * cos(radians(latitude))
        * pow(sin(radians(longitude - prev_longitude) / 2), 2)
    )) as km
from seq
where prev_station_id is not null
    and 6371 * 2 * asin(sqrt(
        pow(sin(radians(latitude - prev_latitude) / 2), 2)
        + cos(radians(prev_latitude)) * cos(radians(latitude))
        * pow(sin(radians(longitude - prev_longitude) / 2), 2)
    )) > 6
