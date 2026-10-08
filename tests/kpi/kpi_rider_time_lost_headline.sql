-- The rider-time-lost tile (average weekday) recomputed from the facts and the rider weights,
-- not from the marts: per station, line, date and period, gated entries x (expected wait with
-- actual gaps - expected wait with scheduled gaps + average excess on the segments starting
-- there), gaps over wait_max_headway_seconds left out. The same with the gaps over 1 hour that
-- count as passenger waits (tile with_gaps_seconds), using the recorded pieces of each gap from
-- fct_suspension_gaps. Tolerance: 1e-6 relative.
with events as (
    select
        events.*,
        dates.day_type
    from {{ ref('fct_trip_stop_events') }} as events
    inner join {{ ref('dim_dates') }} as dates on events.date_key = dates.date_key
    where events.has_headway_comparison
),

gap_pieces as (
    select
        trip_stop_event_key,
        is_passenger_wait,
        recorded_gap_squared_sum
    from {{ ref('fct_suspension_gaps') }}
),

waits as (
    select
        station_id,
        line_id,
        date_key,
        day_type,
        service_period_id,
        sum(cast(headway_seconds as double) * headway_seconds) filter (where is_short)
        / (2 * sum(headway_seconds) filter (where is_short))
        - sum(cast(scheduled_headway_seconds as double) * scheduled_headway_seconds) filter (where is_short)
        / (2 * sum(scheduled_headway_seconds) filter (where is_short)) as excess_wait,
        sum(case when is_short then cast(headway_seconds as double) * headway_seconds else recorded_gap_squared_sum end)
        filter (where is_short or is_passenger_wait)
        / (2 * sum(headway_seconds) filter (where is_short or is_passenger_wait))
        - sum(cast(scheduled_headway_seconds as double) * scheduled_headway_seconds)
        filter (where is_short or is_passenger_wait)
        / (2 * sum(scheduled_headway_seconds) filter (where is_short or is_passenger_wait)) as excess_wait_with_gaps
    from (
        select
            events.*,
            events.headway_seconds <= {{ var('wait_max_headway_seconds') }} as is_short,
            coalesce(gap_pieces.is_passenger_wait, false) as is_passenger_wait,
            gap_pieces.recorded_gap_squared_sum
        from events
        left join gap_pieces on events.trip_stop_event_key = gap_pieces.trip_stop_event_key
    ) as classified
    group by all
),

rides as (
    select
        traversals.from_station_id as station_id,
        traversals.line_id,
        traversals.date_key,
        traversals.day_type,
        traversals.service_period_id,
        avg(traversals.net_excess_seconds) as excess_ride
    from {{ ref('fct_segment_traversals') }} as traversals
    where traversals.is_compared
    group by all
),

cells as (
    select
        coalesce(waits.station_id, rides.station_id) as station_id,
        coalesce(waits.line_id, rides.line_id) as line_id,
        coalesce(waits.date_key, rides.date_key) as date_key,
        coalesce(waits.day_type, rides.day_type) as day_type,
        coalesce(waits.service_period_id, rides.service_period_id) as service_period_id,
        coalesce(waits.excess_wait, 0) + coalesce(rides.excess_ride, 0) as excess_per_rider,
        coalesce(waits.excess_wait_with_gaps, 0) + coalesce(rides.excess_ride, 0) as excess_per_rider_with_gaps
    from waits
    full outer join rides
        on
            waits.station_id = rides.station_id
            and waits.line_id = rides.line_id
            and waits.date_key = rides.date_key
            and waits.service_period_id = rides.service_period_id
),

weighted as (
    select
        cells.date_key,
        sum(riders.avg_daily_gated_entries * cells.excess_per_rider) as rider_seconds_lost,
        sum(riders.avg_daily_gated_entries * cells.excess_per_rider_with_gaps) as rider_seconds_lost_with_gaps
    from cells
    inner join {{ ref('int_station_period_riders') }} as riders
        on
            cells.station_id = riders.station_id
            and cells.line_id = riders.line_id
            and cells.day_type = riders.day_type
            and cells.service_period_id = riders.service_period_id
    where cells.day_type = 'weekday'
    group by cells.date_key
),

fact as (
    select
        avg(rider_seconds_lost) as weekday_seconds,
        avg(rider_seconds_lost_with_gaps) as weekday_with_gaps_seconds
    from weighted
)

select
    tiles.value_number,
    cast(tiles.tile ->> 'value_seconds' as double) as json_value,
    fact.weekday_seconds
from fact
left join {{ ref('board_tiles') }} as tiles on tiles.tile_id = 'rider_time_lost'
where
    tiles.value_number is null
    or fact.weekday_seconds is null
    or abs(tiles.value_number - fact.weekday_seconds) > 1e-6 * abs(fact.weekday_seconds)
    or abs(cast(tiles.tile ->> 'with_gaps_seconds' as double) - fact.weekday_with_gaps_seconds)
    > 1e-6 * abs(fact.weekday_with_gaps_seconds)
    or cast(tiles.tile ->> 'value_seconds' as double) != tiles.value_number
    or (tiles.tile ->> 'value_label') != {{ format_duration('tiles.value_number') }}
