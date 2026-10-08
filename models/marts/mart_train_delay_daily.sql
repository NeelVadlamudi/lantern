-- Grain: one row per service date. Measured train delay: recorded train run time over the
-- schedule, summed over every stop-to-stop run in int_train_runs (a run = a trip-stop event
-- after the trip's first observed stop; it spans any stops not observed in between).
-- Exact seconds from the recorded data; nothing is capped or estimated.
--   positive_excess_seconds = sum of max(run - scheduled, 0) over compared runs
--   net_excess_seconds      = sum of (run - scheduled) over compared runs, so runs faster
--                             than scheduled offset slower ones
--   run = actual_run_seconds minus the terminal platform hold when that hold is inside it
--   (see int_train_runs), so
--   net_excess_seconds = actual_run_seconds_sum - terminal_hold_in_actual_seconds_sum
--                        - scheduled_run_seconds_sum
-- terminal_hold_seconds_sum is all recorded time on terminal platforms before departure
-- (terminal_departure_runs runs), reported on its own and not part of the delay.
-- A run is compared when both its actual and scheduled run times are positive. Runs over
-- var('travel_outlier_seconds') (30 min) are included and also counted on their own in long_run_*.
-- Runs that cannot be compared are counted by reason, never dropped silently:
--   runs_actual_missing / runs_scheduled_missing: a timestamp or the scheduled time is missing
--   runs_actual_not_positive: recorded arrival at or before the previous arrival (a LAMP
--     timestamp problem, not a run time); actual_not_positive_net_seconds sums actual - scheduled
--   runs_scheduled_not_positive: scheduled time zero or negative; scheduled_not_positive_net_seconds
-- runs_observed = runs_compared + the four counts.

with runs as (

    select * from {{ ref('int_train_runs') }}

),

daily as (

    select
        date_key,
        count(*) as runs_observed,
        count(*) filter (where run_comparison_status = 'compared') as runs_compared,
        count(distinct trip_key) filter (where run_comparison_status = 'compared') as trips_compared,
        sum(actual_run_seconds) filter (where run_comparison_status = 'compared') as actual_run_seconds_sum,
        sum(scheduled_run_seconds) filter (where run_comparison_status = 'compared') as scheduled_run_seconds_sum,
        sum(terminal_hold_in_actual_seconds) filter (where run_comparison_status = 'compared')
            as terminal_hold_in_actual_seconds_sum,
        sum(positive_excess_seconds) as positive_excess_seconds,
        sum(net_excess_seconds) as net_excess_seconds,
        count(*) filter (where is_long_run) as long_runs,
        sum(run_seconds) filter (where is_long_run) as long_run_seconds,
        sum(positive_excess_seconds) filter (where is_long_run) as long_run_positive_excess_seconds,
        sum(net_excess_seconds) filter (where is_long_run) as long_run_net_excess_seconds,
        count(*) filter (where is_terminal_departure) as terminal_departure_runs,
        count(terminal_hold_seconds) as terminal_hold_runs,
        sum(terminal_hold_seconds) as terminal_hold_seconds_sum,
        count(*) filter (where run_comparison_status = 'actual_missing') as runs_actual_missing,
        count(*) filter (where run_comparison_status = 'scheduled_missing') as runs_scheduled_missing,
        count(*) filter (where run_comparison_status = 'actual_not_positive') as runs_actual_not_positive,
        sum(actual_run_seconds - scheduled_run_seconds) filter (where run_comparison_status = 'actual_not_positive')
            as actual_not_positive_net_seconds,
        count(*) filter (where run_comparison_status = 'scheduled_not_positive') as runs_scheduled_not_positive,
        sum(actual_run_seconds - scheduled_run_seconds)
        filter (where run_comparison_status = 'scheduled_not_positive') as scheduled_not_positive_net_seconds
    from runs
    group by date_key

)

select
    cast(dates.date_day as date) as service_date,
    cast(daily.date_key as integer) as date_key,
    cast(dates.day_type as varchar) as day_type,
    cast(dates.is_holiday as boolean) as is_holiday,
    cast(daily.runs_observed as bigint) as runs_observed,
    cast(daily.runs_compared as bigint) as runs_compared,
    cast(daily.trips_compared as bigint) as trips_compared,
    cast(coalesce(daily.actual_run_seconds_sum, 0) as bigint) as actual_run_seconds_sum,
    cast(coalesce(daily.scheduled_run_seconds_sum, 0) as bigint) as scheduled_run_seconds_sum,
    cast(coalesce(daily.terminal_hold_in_actual_seconds_sum, 0) as bigint) as terminal_hold_in_actual_seconds_sum,
    cast(coalesce(daily.positive_excess_seconds, 0) as bigint) as positive_excess_seconds,
    cast(coalesce(daily.net_excess_seconds, 0) as bigint) as net_excess_seconds,
    cast(daily.positive_excess_seconds / nullif(daily.runs_compared, 0) as double) as positive_excess_seconds_per_run,
    cast(daily.net_excess_seconds / nullif(daily.runs_compared, 0) as double) as net_excess_seconds_per_run,
    cast(daily.long_runs as bigint) as long_runs,
    cast(coalesce(daily.long_run_seconds, 0) as bigint) as long_run_seconds,
    cast(coalesce(daily.long_run_positive_excess_seconds, 0) as bigint) as long_run_positive_excess_seconds,
    cast(coalesce(daily.long_run_net_excess_seconds, 0) as bigint) as long_run_net_excess_seconds,
    cast(daily.terminal_departure_runs as bigint) as terminal_departure_runs,
    cast(daily.terminal_hold_runs as bigint) as terminal_hold_runs,
    cast(coalesce(daily.terminal_hold_seconds_sum, 0) as bigint) as terminal_hold_seconds_sum,
    cast(daily.runs_actual_missing as bigint) as runs_actual_missing,
    cast(daily.runs_scheduled_missing as bigint) as runs_scheduled_missing,
    cast(daily.runs_actual_not_positive as bigint) as runs_actual_not_positive,
    cast(coalesce(daily.actual_not_positive_net_seconds, 0) as bigint) as actual_not_positive_net_seconds,
    cast(daily.runs_scheduled_not_positive as bigint) as runs_scheduled_not_positive,
    cast(coalesce(daily.scheduled_not_positive_net_seconds, 0) as bigint) as scheduled_not_positive_net_seconds
from daily
inner join {{ ref('dim_dates') }} as dates on daily.date_key = dates.date_key
