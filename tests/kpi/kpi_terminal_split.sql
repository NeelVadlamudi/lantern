-- Run time splits in fct_segment_traversals add up to what LAMP recorded, nothing removed:
--   dwell at the start station + in-motion time = recorded span (arrival to arrival);
--   after a trip's first segment, actual_run_seconds = recorded span; on the first segment,
--   actual_run_seconds = in-motion time (the platform time at the origin is not run time);
--   terminal_hold_seconds is the dwell at the start station on terminal departures and null
--   elsewhere; actual_run_seconds = run_seconds + terminal_hold_in_actual_seconds; on terminal
--   departures with a recorded hold, run_seconds is the in-motion time; net excess = run -
--   scheduled and positive excess = max(net, 0) on compared runs;
--   segment totals in mart_segment_daily equal the sums over the runs.
with traversals as (
    select * from {{ ref('fct_segment_traversals') }}
),

run_checks as (
    select
        'dwell + in motion = span' as check_name,
        segment_traversal_key as row_id
    from traversals
    where dwell_at_start_seconds + in_motion_seconds != recorded_span_seconds
    union all
    select
        'actual = span after the first segment' as check_name,
        segment_traversal_key as row_id
    from traversals
    where not is_first_observed_segment and actual_run_seconds != recorded_span_seconds
    union all
    select
        'actual = in motion on the first segment' as check_name,
        segment_traversal_key as row_id
    from traversals
    where is_first_observed_segment and actual_run_seconds != in_motion_seconds
    union all
    select
        'terminal hold only on terminal departures' as check_name,
        segment_traversal_key as row_id
    from traversals
    where
        (not is_terminal_departure and terminal_hold_seconds is not null)
        or (is_terminal_departure and terminal_hold_seconds is distinct from dwell_at_start_seconds)
    union all
    select
        'actual = run + hold inside it' as check_name,
        segment_traversal_key as row_id
    from traversals
    where actual_run_seconds != run_seconds + coalesce(terminal_hold_in_actual_seconds, 0)
    union all
    select
        'terminal departure run = in motion' as check_name,
        segment_traversal_key as row_id
    from traversals
    where is_terminal_departure and dwell_at_start_seconds is not null and run_seconds != in_motion_seconds
    union all
    select
        'excess from run time' as check_name,
        segment_traversal_key as row_id
    from traversals
    where
        is_compared
        and (
            net_excess_seconds != run_seconds - scheduled_run_seconds
            or positive_excess_seconds != greatest(net_excess_seconds, 0)
        )
),

total_checks as (
    select
        'segment day totals' as check_name,
        runs.segment_id || ' ' || runs.date_key as row_id
    from (
        select
            segment_id,
            date_key,
            count(*) as runs_observed,
            coalesce(sum(positive_excess_seconds), 0) as positive_sum,
            coalesce(sum(net_excess_seconds), 0) as net_sum,
            coalesce(sum(terminal_hold_seconds), 0) as hold_sum
        from traversals
        group by segment_id, date_key
    ) as runs
    inner join {{ ref('mart_segment_daily') }} as segment_days
        on runs.segment_id = segment_days.segment_id and runs.date_key = segment_days.date_key
    where
        runs.runs_observed != segment_days.runs_observed
        or runs.positive_sum != segment_days.positive_excess_seconds_sum
        or runs.net_sum != segment_days.net_excess_seconds_sum
        or runs.hold_sum != segment_days.terminal_hold_seconds_sum
)

select * from run_checks
union all
select * from total_checks
