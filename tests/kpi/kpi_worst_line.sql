-- Worst-line tile = route with the highest per-trip late share in fct_trips.
with fact as (
    select
        route_id,
        avg(cast(is_late_trip as int)) as late_trip_share
    from {{ ref('fct_trips') }}
    where compared_segments > 0
    group by route_id
    order by late_trip_share desc
    limit 1
)

select
    tiles.value_text as board_route,
    tiles.value_number as board_value,
    fact.*
from {{ ref('board_tiles') }} as tiles
cross join fact
where tiles.tile_id = 'worst_line'
    and (tiles.value_text != fact.route_id or abs(tiles.value_number - fact.late_trip_share) > 0.0001)
