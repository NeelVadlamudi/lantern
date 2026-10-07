-- Every route id in the map station lists must be an MBTA V3 API subway route id, so the board
-- can match stations to live vehicle positions.
select
    station_id,
    route_id
from {{ ref('board_map_stations') }}, unnest(route_ids) as t (route_id)
where route_id not in ('Red', 'Mattapan', 'Orange', 'Green-B', 'Green-C', 'Green-D', 'Green-E', 'Blue')
