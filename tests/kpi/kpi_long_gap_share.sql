-- Long-gap tile = share of departures with a headway comparison whose gap exceeded
-- long_gap_ratio x the scheduled gap. Recomputed from fct_trip_stop_events. Tolerance 1e-4.
with fact as (
    select avg(cast(is_long_gap as int)) as long_gap_share
    from {{ ref('fct_trip_stop_events') }}
    where has_headway_comparison
)

select
    tiles.value_number as board_value,
    fact.long_gap_share as fact_value
from {{ ref('board_tiles') }} as tiles
cross join fact
where tiles.tile_id = 'long_gap_share'
    and (fact.long_gap_share is null or abs(tiles.value_number - fact.long_gap_share) > 0.0001)
