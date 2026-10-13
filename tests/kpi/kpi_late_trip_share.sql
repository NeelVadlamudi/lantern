-- Matched trips only (trip id in the day's schedule), planned-change line-days excluded.
-- Late-trip tile = share of compared trips in fct_trips that ran more than late_trip_seconds over
-- schedule. Recomputed per trip from the fact, not from the marts. Fails beyond rounding (1e-4).
with fact as (
    select avg(cast(trips.is_late_trip as int)) as late_trip_share
    from {{ ref('fct_trips') }} as trips
    inner join {{ ref('mart_planned_change_line_days') }} as planned
        on trips.route_id = planned.route_id and trips.service_date = planned.service_date
    where trips.compared_segments > 0 and trips.is_matched_trip and not planned.is_planned_change
)

select
    tiles.value_number as board_value,
    fact.late_trip_share as fact_value
from {{ ref('board_tiles') }} as tiles
cross join fact
where tiles.tile_id = 'late_trip_share'
    and (fact.late_trip_share is null or abs(tiles.value_number - fact.late_trip_share) > 0.0001)
