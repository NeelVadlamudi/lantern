-- Worst-line tile = route with the highest per-trip late share in fct_trips (matched trips,
-- planned-change line-days excluded).
with fact as (
    select
        trips.route_id,
        avg(cast(trips.is_late_trip as int)) as late_trip_share
    from {{ ref('fct_trips') }} as trips
    inner join {{ ref('mart_planned_change_line_days') }} as planned
        on trips.route_id = planned.route_id and trips.service_date = planned.service_date
    where trips.compared_segments > 0 and trips.is_matched_trip and not planned.is_planned_change
    group by trips.route_id
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
