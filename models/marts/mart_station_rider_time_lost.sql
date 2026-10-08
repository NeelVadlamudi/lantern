-- Grain: one row per station, line, service date and service period with trains observed.
-- Estimated rider time lost beyond the schedule, in exact seconds (an estimate: gate entries
-- are entries, not riders).
--
-- Per rider (each person entering the station on that line in that period):
--   excess wait  = expected wait with the actual gaps between trains minus expected wait with
--                  the scheduled gaps. Expected wait for someone arriving at a random time is
--                  sum(h^2) / (2 * sum(h)) over the gaps h at the station (fct_trip_stop_events,
--                  departures with a headway comparison). Both directions are pooled.
--   excess ride  = average excess run time of the next segment after boarding: the segments
--                  that start at this station (fct_segment_traversals), all directions pooled.
--                  Riders usually ride more than one segment, so this undercounts in-vehicle
--                  time lost; there is no origin-destination data to do better.
-- Gaps longer than var('wait_max_headway_seconds') (1 hour) are left out of both sums, actual
-- and scheduled: a gap that long is a suspension (shuttle buses) or missing data, and nobody
-- waits on the platform for it. They are counted in suspension_gaps. This makes the estimate
-- lower than it would be if those gaps were real waits.
-- Neither part is clamped at 0: a cell where trains ran closer together or faster than
-- scheduled offsets cells where they ran slower (net time lost).
-- Rider weight = average daily gated entries for the station, line, day type and service
-- period (int_station_period_riders, rider basis window). Stations without fare gates have no
-- weight, so their rider_* columns are null. A missing part (no headway comparison, or no
-- segment starting here, e.g. a terminal in one direction) counts as 0 in rider_seconds_lost.

with events as (

    select * from {{ ref('fct_trip_stop_events') }}

),

traversals as (

    select * from {{ ref('fct_segment_traversals') }}

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

waits as (

    select
        station_id,
        line_id,
        date_key,
        service_period_id,
        count(*) filter (where has_headway_comparison and not wait_gap) as suspension_gaps,
        count(*) filter (where wait_gap) as headway_observations,
        sum(cast(headway_seconds as double)) filter (where wait_gap) as actual_headway_seconds_sum,
        sum(cast(headway_seconds as double) * headway_seconds) filter (where wait_gap)
            as actual_headway_squared_sum,
        sum(cast(scheduled_headway_seconds as double)) filter (where wait_gap)
            as scheduled_headway_seconds_sum,
        sum(cast(scheduled_headway_seconds as double) * scheduled_headway_seconds)
        filter (where wait_gap) as scheduled_headway_squared_sum
    from (
        select
            *,
            has_headway_comparison and headway_seconds <= {{ var('wait_max_headway_seconds') }} as wait_gap
        from events
    ) as events_with_gaps
    group by station_id, line_id, date_key, service_period_id

),

rides as (

    select
        from_station_id as station_id,
        line_id,
        date_key,
        service_period_id,
        count(*) as segment_departures,
        sum(excess_travel_seconds) as excess_ride_seconds_sum
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
        coalesce(waits.suspension_gaps, 0) as suspension_gaps,
        waits.actual_headway_seconds_sum,
        waits.actual_headway_squared_sum,
        waits.scheduled_headway_seconds_sum,
        waits.scheduled_headway_squared_sum,
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
    cast(suspension_gaps as bigint) as suspension_gaps,
    cast(actual_headway_seconds_sum as double) as actual_headway_seconds_sum,
    cast(actual_headway_squared_sum as double) as actual_headway_squared_sum,
    cast(scheduled_headway_seconds_sum as double) as scheduled_headway_seconds_sum,
    cast(scheduled_headway_squared_sum as double) as scheduled_headway_squared_sum,
    cast(actual_expected_wait_seconds as double) as actual_expected_wait_seconds,
    cast(scheduled_expected_wait_seconds as double) as scheduled_expected_wait_seconds,
    cast(actual_expected_wait_seconds - scheduled_expected_wait_seconds as double) as excess_wait_seconds,
    cast(segment_departures as bigint) as segment_departures,
    cast(excess_ride_seconds_sum as bigint) as excess_ride_seconds_sum,
    cast(excess_ride_seconds as double) as excess_ride_seconds,
    cast(avg_daily_gated_entries is not null as boolean) as has_rider_data,
    cast(avg_daily_gated_entries as double) as gated_entries,
    cast(
        avg_daily_gated_entries * coalesce(actual_expected_wait_seconds - scheduled_expected_wait_seconds, 0)
        as double
    ) as rider_wait_seconds_lost,
    cast(avg_daily_gated_entries * coalesce(excess_ride_seconds, 0) as double) as rider_ride_seconds_lost,
    cast(
        avg_daily_gated_entries * (
            coalesce(actual_expected_wait_seconds - scheduled_expected_wait_seconds, 0)
            + coalesce(excess_ride_seconds, 0)
        ) as double
    ) as rider_seconds_lost
from per_rider
