-- Grain: one row per train run over one track segment (dim_segments): a run in
-- int_train_runs whose previous observed stop is the segment's start station and whose stop
-- is its end station. Every such run is kept, compared to the schedule or not;
-- run_comparison_status says which, and only 'compared' rows carry excess values.
-- Observed stop pairs that are not consecutive on a canonical pattern (a skipped or missing
-- stop) are left out here; they are still in int_train_runs and in mart_train_delay_daily.
-- All run time columns, the terminal split and the excess definitions come from
-- int_train_runs (see that model):
--   net_excess_seconds = run_seconds - scheduled_run_seconds; positive_excess_seconds =
--   max(net, 0); run_seconds = actual_run_seconds minus any terminal hold inside it;
--   terminal_hold_seconds = recorded time on the terminal platform before a terminal departure;
--   terminal arrivals are flagged but not split (LAMP has no timestamp for holding outside).

with runs as (

    select * from {{ ref('int_train_runs') }}

),

segments as (

    select
        segment_id,
        line_id,
        direction_id,
        from_station_id,
        to_station_id
    from {{ ref('dim_segments') }}

)

select
    runs.trip_stop_event_key as segment_traversal_key,
    segments.segment_id,
    runs.trip_key,
    runs.service_date,
    runs.date_key,
    runs.day_type,
    runs.service_period_id,
    runs.line_id,
    runs.route_id,
    runs.branch_route_id,
    runs.direction_id,
    runs.from_station_id,
    runs.to_station_id,
    runs.run_comparison_status,
    runs.is_compared,
    runs.is_long_run,
    runs.actual_run_seconds,
    runs.run_seconds,
    runs.scheduled_run_seconds,
    runs.net_excess_seconds,
    runs.positive_excess_seconds,
    runs.is_first_observed_segment,
    runs.arrived_start_at,
    runs.departed_start_at,
    runs.arrived_at,
    runs.dwell_at_start_seconds,
    runs.in_motion_seconds,
    runs.recorded_span_seconds,
    runs.is_terminal_departure,
    runs.is_terminal_arrival,
    runs.terminal_time_split,
    runs.terminal_hold_seconds,
    runs.terminal_hold_in_actual_seconds
from runs
inner join segments
    on
        runs.line_id = segments.line_id
        and runs.direction_id = segments.direction_id
        and runs.from_station_id = segments.from_station_id
        and runs.to_station_id = segments.to_station_id
