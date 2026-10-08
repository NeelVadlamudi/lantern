{{ config(materialized='table') }}
-- Grain: one row per train run between two observed stops: every trip-stop event in
-- fct_trip_stop_events after the trip's first observed stop (the run from the previous
-- observed stop to this one; it spans any stops not observed in between). Every run is kept,
-- compared to the schedule or not. One definition for mart_train_delay_daily (all runs) and
-- fct_segment_traversals (runs over a dim_segments segment).
-- Stops are ordered by stop_sequence, then event time and key (some trips repeat a
-- stop_sequence, e.g. Mattapan and Union Square trips starting at either end).
--
-- Recorded times (Boston local, from the LAMP timestamps):
--   arrived_start_at  = arrival at the previous observed stop
--   departed_start_at = departure from it (LAMP move time at this stop)
--   arrived_at        = arrival here
--   dwell_at_start_seconds = departed_start_at - arrived_start_at
--   in_motion_seconds      = arrived_at - departed_start_at
--   recorded_span_seconds  = arrived_at - arrived_start_at (= dwell + in motion)
--   actual_run_seconds     = from int_trip_stops__performance: the recorded span, except on a
--                            trip's first observed segment, where it is the in-motion time
-- Terminals (from the run's own branch pattern, int_line_stop_sequence):
--   is_terminal_departure: the previous stop is the first stop of the branch's canonical
--     pattern. terminal_hold_seconds = dwell_at_start_seconds: time on the terminal platform
--     before leaving. When the run is not the trip's first observed segment (LAMP sometimes
--     lists a stop before the terminal), that hold is inside actual_run_seconds; it is split
--     out into terminal_hold_in_actual_seconds, so run_seconds is the in-motion time for every
--     terminal departure.
--   is_terminal_arrival: this stop is the last stop of the branch's pattern. LAMP has only the
--     departure from the previous stop and the arrival at the terminal, so time spent holding
--     outside the terminal cannot be separated and stays in the run.
-- Comparison:
--   run_seconds = actual_run_seconds - coalesce(terminal_hold_in_actual_seconds, 0)
--   run_comparison_status: 'compared' when actual and scheduled run times are both positive,
--     otherwise the reason ('actual_missing', 'scheduled_missing', 'actual_not_positive',
--     'scheduled_not_positive')
--   net_excess_seconds      = run_seconds - scheduled_run_seconds (compared runs)
--   positive_excess_seconds = max(run_seconds - scheduled_run_seconds, 0)
--   is_long_run: compared and run_seconds > var('travel_outlier_seconds') (30 min); kept, flagged.
-- Totals equal what was recorded: actual_run_seconds = run_seconds + terminal_hold_in_actual_seconds.

with stops as (

    select
        trip_stop_event_key,
        moved_at,
        stopped_at
    from {{ ref('stg_lamp__subway_trip_stops') }}

),

events as (

    select
        fct.*,
        {{ to_boston_time('stops.moved_at') }} as departed_start_at,
        {{ to_boston_time('stops.stopped_at') }} as arrived_at,
        lag(fct.station_id) over trip_window as previous_station_id,
        lag({{ to_boston_time('stops.stopped_at') }}) over trip_window as arrived_start_at,
        row_number() over trip_window as stop_position
    from {{ ref('fct_trip_stop_events') }} as fct
    left join stops on fct.trip_stop_event_key = stops.trip_stop_event_key
    window trip_window as (
        partition by fct.trip_key order by fct.stop_sequence, fct.event_local_at, fct.trip_stop_event_key
    )

),

branch_ends as (

    select
        branch_route_id,
        direction_id,
        arg_min(station_id, stop_order) as first_station_id,
        arg_max(station_id, stop_order) as last_station_id
    from {{ ref('int_line_stop_sequence') }}
    group by branch_route_id, direction_id

),

dates as (

    select
        date_key,
        day_type
    from {{ ref('dim_dates') }}

),

timed as (

    select
        events.*,
        dates.day_type,
        events.stop_position = 2 as is_first_observed_segment,
        coalesce(events.previous_station_id = branch_ends.first_station_id, false) as is_terminal_departure,
        coalesce(events.station_id = branch_ends.last_station_id, false) as is_terminal_arrival,
        case
            when events.actual_run_seconds is null then 'actual_missing'
            when events.scheduled_run_seconds is null then 'scheduled_missing'
            when events.actual_run_seconds <= 0 then 'actual_not_positive'
            when events.scheduled_run_seconds <= 0 then 'scheduled_not_positive'
            else 'compared'
        end as run_comparison_status,
        epoch(events.departed_start_at) - epoch(events.arrived_start_at) as dwell_at_start_seconds,
        epoch(events.arrived_at) - epoch(events.departed_start_at) as in_motion_seconds,
        epoch(events.arrived_at) - epoch(events.arrived_start_at) as recorded_span_seconds
    from events
    inner join dates on events.date_key = dates.date_key
    left join branch_ends
        on
            events.branch_route_id = branch_ends.branch_route_id
            and events.direction_id = branch_ends.direction_id
    where events.stop_position > 1

),

split as (

    select
        *,
        case when is_terminal_departure then dwell_at_start_seconds end as terminal_hold_seconds,
        case
            when is_terminal_departure and not is_first_observed_segment then dwell_at_start_seconds
        end as terminal_hold_in_actual_seconds
    from timed

),

runs as (

    select
        *,
        actual_run_seconds - coalesce(terminal_hold_in_actual_seconds, 0) as run_seconds
    from split

)

select
    cast(trip_stop_event_key as varchar) as trip_stop_event_key,
    cast(trip_key as varchar) as trip_key,
    cast(service_date as date) as service_date,
    cast(date_key as integer) as date_key,
    cast(day_type as varchar) as day_type,
    cast(service_period_id as varchar) as service_period_id,
    cast(line_id as varchar) as line_id,
    cast(route_id as varchar) as route_id,
    cast(branch_route_id as varchar) as branch_route_id,
    cast(direction_id as integer) as direction_id,
    cast(previous_station_id as varchar) as from_station_id,
    cast(station_id as varchar) as to_station_id,
    cast(is_first_observed_segment as boolean) as is_first_observed_segment,
    cast(run_comparison_status as varchar) as run_comparison_status,
    cast(run_comparison_status = 'compared' as boolean) as is_compared,
    cast(
        run_comparison_status = 'compared' and run_seconds > {{ var('travel_outlier_seconds') }} as boolean
    ) as is_long_run,
    cast(actual_run_seconds as bigint) as actual_run_seconds,
    cast(run_seconds as bigint) as run_seconds,
    cast(scheduled_run_seconds as bigint) as scheduled_run_seconds,
    cast(
        case when run_comparison_status = 'compared' then run_seconds - scheduled_run_seconds end as bigint
    ) as net_excess_seconds,
    cast(
        case when run_comparison_status = 'compared' then greatest(run_seconds - scheduled_run_seconds, 0) end
        as bigint
    ) as positive_excess_seconds,
    cast(arrived_start_at as timestamp) as arrived_start_at,
    cast(departed_start_at as timestamp) as departed_start_at,
    cast(arrived_at as timestamp) as arrived_at,
    cast(dwell_at_start_seconds as bigint) as dwell_at_start_seconds,
    cast(in_motion_seconds as bigint) as in_motion_seconds,
    cast(recorded_span_seconds as bigint) as recorded_span_seconds,
    cast(is_terminal_departure as boolean) as is_terminal_departure,
    cast(is_terminal_arrival as boolean) as is_terminal_arrival,
    cast(
        case
            when is_terminal_departure and dwell_at_start_seconds is not null then 'departure_hold_split'
            when is_terminal_departure then 'departure_hold_not_recorded'
            when is_terminal_arrival then 'arrival_not_split'
            else 'not_terminal'
        end as varchar
    ) as terminal_time_split,
    cast(terminal_hold_seconds as bigint) as terminal_hold_seconds,
    cast(terminal_hold_in_actual_seconds as bigint) as terminal_hold_in_actual_seconds
from runs
