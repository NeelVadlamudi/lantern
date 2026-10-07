-- Rider tile = weekday fare-gate entries x long-gap share, per station x line x service period
-- cell, each entry counted once. Recomputed from int_station_period_riders and the fact (not the
-- marts). Tolerance: 1 entry or 0.1%, whichever is larger.
with riders as (
    select
        station_id,
        line_id,
        service_period_id,
        avg_daily_gated_entries as entries
    from {{ ref('int_station_period_riders') }}
    where day_type = 'weekday'
),

gaps as (
    select
        events.station_id,
        events.line_id,
        events.service_period_id,
        avg(cast(events.is_long_gap as int)) filter (where events.has_headway_comparison) as long_gap_share
    from {{ ref('fct_trip_stop_events') }} as events
    inner join {{ ref('dim_dates') }} as dates on events.date_key = dates.date_key
    where dates.day_type = 'weekday'
    group by all
),

fact as (
    select sum(riders.entries * gaps.long_gap_share) as entries_in_long_gaps
    from riders
    inner join gaps
        on
            riders.station_id = gaps.station_id
            and riders.line_id = gaps.line_id
            and riders.service_period_id = gaps.service_period_id
)

select
    tiles.value_number as board_value,
    fact.entries_in_long_gaps as fact_value
from {{ ref('board_tiles') }} as tiles
cross join fact
where tiles.tile_id = 'weekday_entries_in_long_gaps'
    and (
        fact.entries_in_long_gaps is null
        or abs(tiles.value_number - fact.entries_in_long_gaps) > greatest(1, 0.001 * fact.entries_in_long_gaps)
    )
