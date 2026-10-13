-- Matched trips only (trip id in the day's schedule), planned-change line-days excluded.
-- Excess tile = average of (actual - scheduled) seconds per compared trip, and the same summed
-- excess as a share of scheduled time. Recomputed from fct_trips. Tolerance: 0.06 s (value is
-- rounded to 0.1 s) and 1e-4 for the share.
with fact as (
    select
        avg(trips.trip_excess_seconds) as avg_trip_excess_seconds,
        sum(trips.trip_excess_seconds) / sum(trips.trip_scheduled_seconds) as share_of_scheduled
    from {{ ref('fct_trips') }} as trips
    inner join {{ ref('mart_planned_change_line_days') }} as planned
        on trips.route_id = planned.route_id and trips.service_date = planned.service_date
    where trips.compared_segments > 0 and trips.is_matched_trip and not planned.is_planned_change
)

select
    tiles.value_number as board_value,
    cast(json_extract(tiles.tile, '$.share_of_scheduled') as double) as board_share,
    fact.avg_trip_excess_seconds,
    fact.share_of_scheduled
from {{ ref('board_tiles') }} as tiles
cross join fact
where tiles.tile_id = 'avg_trip_excess_seconds'
    and (
        fact.avg_trip_excess_seconds is null
        or abs(tiles.value_number - fact.avg_trip_excess_seconds) > 0.06
        or abs(cast(json_extract(tiles.tile, '$.share_of_scheduled') as double) - fact.share_of_scheduled) > 0.0001
    )
