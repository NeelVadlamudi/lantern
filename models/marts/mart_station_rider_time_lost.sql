-- Grain: one row per station, line, service date and service period with trains observed.
-- Estimated rider time lost beyond the schedule, in exact seconds. An estimate: it weights by
-- people entering the station through fare gates (entries, not riders) and assumes riders
-- arrive at random times.
--
-- Per rider (each person entering the station on that line in that period):
--   excess wait  = expected wait with the actual gaps between trains minus expected wait with
--                  the scheduled gaps. Expected wait for someone arriving at a random time is
--                  sum(h^2) / (2 * sum(h)) over the gaps h at the station (fct_trip_stop_events,
--                  departures with a headway comparison). Both directions are pooled.
--   excess ride  = average net excess run time of the next segment after boarding: the
--                  compared runs on segments that start at this station (fct_segment_traversals),
--                  all directions pooled, runs over 30 minutes included. Riders usually ride
--                  more than one segment, so this undercounts in-vehicle time lost; there is no
--                  origin-destination data to do better.
-- Gaps longer than var('wait_max_headway_seconds') (1 hour) are kept in their own columns
-- (suspension_gap_*), and wait is given two ways:
--   *_wait_* (no suffix)  gaps of 1 hour or less only
--   *_with_gaps           also the gaps over 1 hour that fct_suspension_gaps keeps as passenger
--                         waits (is_passenger_wait). Where trains were recorded leaving the
--                         platform inside such a gap, its squared term is the sum over the
--                         recorded pieces (recorded_gap_squared_sum), so it counts as the waits
--                         riders had. Gaps the recorded data shows were not waits (running
--                         through the overnight break) are counted in non_wait_gap_* and left
--                         out of both.
-- Neither part is clamped at 0: a cell where trains ran closer together or faster than
-- scheduled offsets cells where they ran slower (net time lost).
-- Rider weight = average daily gated entries for the station, line, day type and service
-- period (int_station_period_riders, rider basis window). Stations without fare gates have no
-- weight, so their rider_* columns are null. A missing part (no headway comparison, or no
-- segment starting here, e.g. a terminal in one direction) counts as 0 in rider_seconds_lost.
-- share_of_total_rider_time_lost = this cell's rider_seconds_lost (wait + ride, gaps of 1 hour
-- or less) / the sum over all cells in the window. Not clamped, so a cell with net negative
-- time lost has a negative share.

with events as (

    select * from {{ ref('fct_trip_stop_events') }}

),

gaps as (

    select
        trip_stop_event_key,
        is_passenger_wait,
        recorded_gap_squared_sum
    from {{ ref('fct_suspension_gaps') }}

),

traversals as (

    select * from {{ ref('fct_segment_traversals') }}
    where is_compared

),

dates as (

    select
        date_key,
        date_day,
        day_type
    from {{ ref('dim_dates') }}

),

riders as (

    select
        station_id,
        line_id,
        day_type,
        service_period_id,
        avg_daily_gated_entries
    from {{ ref('int_station_period_riders') }}

),

classified as (

    select
        events.station_id,
        events.line_id,
        events.date_key,
        events.service_period_id,
        cast(events.headway_seconds as double) as headway_seconds,
        cast(events.scheduled_headway_seconds as double) as scheduled_headway_seconds,
        coalesce(
            events.has_headway_comparison and events.headway_seconds <= {{ var('wait_max_headway_seconds') }},
            false
        ) as is_short_gap,
        coalesce(
            events.has_headway_comparison and events.headway_seconds > {{ var('wait_max_headway_seconds') }},
            false
        ) as is_suspension_gap,
        coalesce(gaps.is_passenger_wait, false) as is_waited_suspension_gap,
        gaps.recorded_gap_squared_sum
    from events
    left join gaps on events.trip_stop_event_key = gaps.trip_stop_event_key
    -- every recorded stop event keeps its cell (as before), with or without a headway comparison

),

waits as (

    select
        station_id,
        line_id,
        date_key,
        service_period_id,
        count(*) filter (where is_short_gap) as headway_observations,
        sum(headway_seconds) filter (where is_short_gap) as actual_headway_seconds_sum,
        sum(headway_seconds * headway_seconds) filter (where is_short_gap) as actual_headway_squared_sum,
        sum(scheduled_headway_seconds) filter (where is_short_gap) as scheduled_headway_seconds_sum,
        sum(scheduled_headway_seconds * scheduled_headway_seconds) filter (where is_short_gap)
            as scheduled_headway_squared_sum,
        count(*) filter (where is_suspension_gap) as suspension_gap_count,
        sum(headway_seconds) filter (where is_suspension_gap) as suspension_gap_seconds,
        sum(scheduled_headway_seconds) filter (where is_suspension_gap) as suspension_gap_scheduled_seconds,
        count(*) filter (where is_waited_suspension_gap) as waited_gap_count,
        sum(headway_seconds) filter (where is_waited_suspension_gap) as waited_gap_seconds,
        sum(recorded_gap_squared_sum) filter (where is_waited_suspension_gap) as waited_gap_squared_sum,
        sum(scheduled_headway_seconds) filter (where is_waited_suspension_gap) as waited_gap_scheduled_seconds,
        sum(scheduled_headway_seconds * scheduled_headway_seconds) filter (where is_waited_suspension_gap)
            as waited_gap_scheduled_squared_sum,
        count(*) filter (where is_suspension_gap and not is_waited_suspension_gap) as non_wait_gap_count,
        sum(headway_seconds) filter (where is_suspension_gap and not is_waited_suspension_gap)
            as non_wait_gap_seconds
    from classified
    group by station_id, line_id, date_key, service_period_id

),

rides as (

    select
        from_station_id as station_id,
        line_id,
        date_key,
        service_period_id,
        count(*) as segment_departures,
        sum(net_excess_seconds) as excess_ride_seconds_sum
    from traversals
    group by from_station_id, line_id, date_key, service_period_id

),

cells as (

    select
        coalesce(waits.station_id, rides.station_id) as station_id,
        coalesce(waits.line_id, rides.line_id) as line_id,
        coalesce(waits.date_key, rides.date_key) as date_key,
        coalesce(waits.service_period_id, rides.service_period_id) as service_period_id,
        coalesce(waits.headway_observations, 0) as headway_observations,
        waits.actual_headway_seconds_sum,
        waits.actual_headway_squared_sum,
        waits.scheduled_headway_seconds_sum,
        waits.scheduled_headway_squared_sum,
        coalesce(waits.suspension_gap_count, 0) as suspension_gap_count,
        coalesce(waits.suspension_gap_seconds, 0) as suspension_gap_seconds,
        coalesce(waits.suspension_gap_scheduled_seconds, 0) as suspension_gap_scheduled_seconds,
        coalesce(waits.waited_gap_count, 0) as waited_gap_count,
        coalesce(waits.waited_gap_seconds, 0) as waited_gap_seconds,
        coalesce(waits.waited_gap_squared_sum, 0) as waited_gap_squared_sum,
        coalesce(waits.waited_gap_scheduled_seconds, 0) as waited_gap_scheduled_seconds,
        coalesce(waits.waited_gap_scheduled_squared_sum, 0) as waited_gap_scheduled_squared_sum,
        coalesce(waits.non_wait_gap_count, 0) as non_wait_gap_count,
        coalesce(waits.non_wait_gap_seconds, 0) as non_wait_gap_seconds,
        coalesce(rides.segment_departures, 0) as segment_departures,
        rides.excess_ride_seconds_sum
    from waits
    full outer join rides
        on
            waits.station_id = rides.station_id
            and waits.line_id = rides.line_id
            and waits.date_key = rides.date_key
            and waits.service_period_id = rides.service_period_id

),

per_rider as (

    select
        cells.*,
        dates.date_day as service_date,
        dates.day_type,
        cells.actual_headway_squared_sum / nullif(2 * cells.actual_headway_seconds_sum, 0)
            as actual_expected_wait_seconds,
        cells.scheduled_headway_squared_sum / nullif(2 * cells.scheduled_headway_seconds_sum, 0)
            as scheduled_expected_wait_seconds,
        (coalesce(cells.actual_headway_squared_sum, 0) + cells.waited_gap_squared_sum)
        / nullif(2 * (coalesce(cells.actual_headway_seconds_sum, 0) + cells.waited_gap_seconds), 0)
            as actual_expected_wait_with_gaps_seconds,
        (coalesce(cells.scheduled_headway_squared_sum, 0) + cells.waited_gap_scheduled_squared_sum)
        / nullif(2 * (coalesce(cells.scheduled_headway_seconds_sum, 0) + cells.waited_gap_scheduled_seconds), 0)
            as scheduled_expected_wait_with_gaps_seconds,
        cells.excess_ride_seconds_sum / nullif(cells.segment_departures, 0) as excess_ride_seconds,
        riders.avg_daily_gated_entries
    from cells
    inner join dates on cells.date_key = dates.date_key
    left join riders
        on
            cells.station_id = riders.station_id
            and cells.line_id = riders.line_id
            and dates.day_type = riders.day_type
            and cells.service_period_id = riders.service_period_id

),

measured as (

    select
        *,
        actual_expected_wait_seconds - scheduled_expected_wait_seconds as excess_wait_seconds,
        actual_expected_wait_with_gaps_seconds - scheduled_expected_wait_with_gaps_seconds
            as excess_wait_with_gaps_seconds
    from per_rider

)

select
    {{ dbt_utils.generate_surrogate_key(['station_id', 'line_id', 'date_key', 'service_period_id']) }}
        as station_line_day_period_key,
    cast(station_id as varchar) as station_id,
    cast(line_id as varchar) as line_id,
    cast(service_date as date) as service_date,
    cast(date_key as integer) as date_key,
    cast(day_type as varchar) as day_type,
    cast(service_period_id as varchar) as service_period_id,
    cast(headway_observations as bigint) as headway_observations,
    cast(actual_headway_seconds_sum as double) as actual_headway_seconds_sum,
    cast(actual_headway_squared_sum as double) as actual_headway_squared_sum,
    cast(scheduled_headway_seconds_sum as double) as scheduled_headway_seconds_sum,
    cast(scheduled_headway_squared_sum as double) as scheduled_headway_squared_sum,
    cast(suspension_gap_count as bigint) as suspension_gap_count,
    cast(suspension_gap_seconds as double) as suspension_gap_seconds,
    cast(suspension_gap_scheduled_seconds as double) as suspension_gap_scheduled_seconds,
    cast(waited_gap_count as bigint) as waited_gap_count,
    cast(waited_gap_seconds as double) as waited_gap_seconds,
    cast(waited_gap_squared_sum as double) as waited_gap_squared_sum,
    cast(waited_gap_scheduled_seconds as double) as waited_gap_scheduled_seconds,
    cast(waited_gap_scheduled_squared_sum as double) as waited_gap_scheduled_squared_sum,
    cast(non_wait_gap_count as bigint) as non_wait_gap_count,
    cast(non_wait_gap_seconds as double) as non_wait_gap_seconds,
    cast(actual_expected_wait_seconds as double) as actual_expected_wait_seconds,
    cast(scheduled_expected_wait_seconds as double) as scheduled_expected_wait_seconds,
    cast(excess_wait_seconds as double) as excess_wait_seconds,
    cast(actual_expected_wait_with_gaps_seconds as double) as actual_expected_wait_with_gaps_seconds,
    cast(scheduled_expected_wait_with_gaps_seconds as double) as scheduled_expected_wait_with_gaps_seconds,
    cast(excess_wait_with_gaps_seconds as double) as excess_wait_with_gaps_seconds,
    cast(segment_departures as bigint) as segment_departures,
    cast(excess_ride_seconds_sum as bigint) as excess_ride_seconds_sum,
    cast(excess_ride_seconds as double) as excess_ride_seconds,
    cast(avg_daily_gated_entries is not null as boolean) as has_rider_data,
    cast(avg_daily_gated_entries as double) as gated_entries,
    cast(avg_daily_gated_entries * coalesce(excess_wait_seconds, 0) as double) as rider_wait_seconds_lost,
    cast(avg_daily_gated_entries * coalesce(excess_wait_with_gaps_seconds, 0) as double)
        as rider_wait_seconds_lost_with_gaps,
    cast(avg_daily_gated_entries * coalesce(excess_ride_seconds, 0) as double) as rider_ride_seconds_lost,
    cast(
        avg_daily_gated_entries * (coalesce(excess_wait_seconds, 0) + coalesce(excess_ride_seconds, 0)) as double
    ) as rider_seconds_lost,
    cast(
        avg_daily_gated_entries * (coalesce(excess_wait_with_gaps_seconds, 0) + coalesce(excess_ride_seconds, 0))
        as double
    ) as rider_seconds_lost_with_gaps,
    cast(
        avg_daily_gated_entries * (coalesce(excess_wait_seconds, 0) + coalesce(excess_ride_seconds, 0))
        / sum(avg_daily_gated_entries * (coalesce(excess_wait_seconds, 0) + coalesce(excess_ride_seconds, 0))) over ()
        as double
    ) as share_of_total_rider_time_lost
from measured
