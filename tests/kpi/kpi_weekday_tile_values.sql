-- value_weekday on the late, excess and long-gap tiles equals the same measure recomputed from
-- the facts over weekday service dates only (dim_dates.day_type = 'weekday'; holidays excluded).
-- Tolerance 1e-4 for shares, 0.06 s for seconds.
with weekday_trips as (
    select
        avg(cast(trips.is_late_trip as int)) as late_trip_share,
        avg(trips.trip_excess_seconds) as avg_trip_excess_seconds
    from {{ ref('fct_trips') }} as trips
    inner join {{ ref('dim_dates') }} as dates on trips.date_key = dates.date_key
    where trips.compared_segments > 0 and dates.day_type = 'weekday'
),

weekday_gaps as (
    select avg(cast(events.is_long_gap as int)) as long_gap_share
    from {{ ref('fct_trip_stop_events') }} as events
    inner join {{ ref('dim_dates') }} as dates on events.date_key = dates.date_key
    where events.has_headway_comparison and dates.day_type = 'weekday'
),

expected as (
    select
        'late_trip_share' as tile_id,
        late_trip_share as fact_value,
        0.0001 as tolerance
    from weekday_trips
    union all
    select
        'avg_trip_excess_seconds' as tile_id,
        avg_trip_excess_seconds as fact_value,
        0.06 as tolerance
    from weekday_trips
    union all
    select
        'long_gap_share' as tile_id,
        long_gap_share as fact_value,
        0.0001 as tolerance
    from weekday_gaps
)

select
    expected.tile_id,
    tiles.value_weekday,
    cast(tiles.tile ->> 'value_weekday' as double) as json_value,
    expected.fact_value
from expected
left join {{ ref('board_tiles') }} as tiles on expected.tile_id = tiles.tile_id
where
    tiles.value_weekday is null
    or expected.fact_value is null
    or abs(tiles.value_weekday - expected.fact_value) > expected.tolerance
    or cast(tiles.tile ->> 'value_weekday' as double) != tiles.value_weekday
