-- Every route id in the map station lists must be an MBTA V3 API route id, so the board can match
-- stations to live vehicle positions: subway ids in route_ids, CR- ids in cr_route_ids.
select
    station_id,
    route_id
from {{ ref('board_map_stations') }}, unnest(route_ids) as t (route_id)
where route_id not in ('Red', 'Mattapan', 'Orange', 'Green-B', 'Green-C', 'Green-D', 'Green-E', 'Blue')

union all

select
    station_id,
    route_id
from {{ ref('board_map_stations') }}, unnest(cr_route_ids) as t (route_id)
where route_id not in (select r.route_id from {{ ref('dim_cr_routes') }} as r)
