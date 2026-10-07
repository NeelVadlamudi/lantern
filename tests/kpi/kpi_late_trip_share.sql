-- Late-trip tile = share of compared trips in fct_trips that ran more than late_trip_seconds over
-- schedule. Recomputed per trip from the fact, not from the marts. Fails beyond rounding (1e-4).
with fact as (
    select avg(cast(is_late_trip as int)) as late_trip_share
    from {{ ref('fct_trips') }}
    where compared_segments > 0
)

select
    tiles.value_number as board_value,
    fact.late_trip_share as fact_value
from {{ ref('board_tiles') }} as tiles
cross join fact
where tiles.tile_id = 'late_trip_share'
    and (fact.late_trip_share is null or abs(tiles.value_number - fact.late_trip_share) > 0.0001)
