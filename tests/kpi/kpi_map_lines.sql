-- Every branch and direction in the board map: stop list equals mart_line_stop_sequence in
-- order, has no repeats, every stop is a map station, the track shape has 2+ points inside
-- Greater Boston, and all nine branches are present.
with board_lines as (
    select
        map_line ->> 'branch_route_id' as branch_route_id,
        cast(map_line ->> 'direction_id' as int) as direction_id,
        cast(map_line -> 'stops' as varchar[]) as stops,
        cast(map_line -> 'shape' as double[][]) as shape
    from (select unnest(cast(map -> '$.lines' as json[])) as map_line from {{ ref('board_payload') }})
),

mart_lines as (
    select
        branch_route_id,
        direction_id,
        list(station_id order by stop_order) as stops,
        max(stop_order) = count(*) and min(stop_order) = 1 as contiguous
    from {{ ref('mart_line_stop_sequence') }}
    group by all
),

map_stations as (
    select list(station ->> 'station_id') as ids
    from (select unnest(cast(map -> '$.stations' as json[])) as station from {{ ref('board_payload') }})
),

line_problems as (
    select
        board_lines.branch_route_id,
        board_lines.direction_id,
        'stop list' as problem
    from board_lines
    left join mart_lines
        on board_lines.branch_route_id = mart_lines.branch_route_id
            and board_lines.direction_id = mart_lines.direction_id
    cross join map_stations
    where
        mart_lines.stops is null
        or not mart_lines.contiguous
        or board_lines.stops != mart_lines.stops
        or len(list_distinct(board_lines.stops)) != len(board_lines.stops)
        or not list_has_all(map_stations.ids, board_lines.stops)

    union all

    select
        branch_route_id,
        direction_id,
        'track shape' as problem
    from board_lines
    where
        coalesce(len(shape), 0) < 2
        or len(list_filter(shape, p -> not (p[1] between -71.4 and -70.8 and p[2] between 42.1 and 42.6))) > 0
),

branches as (
    select unnest(['Red-A', 'Red-B', 'Mattapan', 'Orange', 'Green-B', 'Green-C', 'Green-D', 'Green-E', 'Blue'])
        as branch_route_id
)

select * from line_problems

union all

select
    branches.branch_route_id,
    null as direction_id,
    'branch missing from map' as problem
from branches
left join board_lines on branches.branch_route_id = board_lines.branch_route_id
where board_lines.branch_route_id is null
