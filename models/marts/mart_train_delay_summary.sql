-- Grain: one row per day basis: 'weekday' (weekdays that are not holidays) and 'all_days'.
-- The headline measured train delay over the loaded window, from mart_train_delay_daily, in
-- exact seconds:
--   avg_daily_positive_excess_seconds = total positive excess / service dates of the basis
--     ("train-seconds over schedule per average weekday" for the weekday row)
--   avg_daily_net_excess_seconds      = total net excess / service dates
--   positive_excess_seconds_per_run   = total positive excess / compared runs (the same for net)
--   *_per_trip                        = the same per compared trip
-- long_run_* and *_excl_long_runs split out runs over var('travel_outlier_seconds') (30 min):
-- with + without = total, so the long runs can be read on their own. Runs that could not be
-- compared are counted by reason (see mart_train_delay_daily). terminal_hold_* is the recorded
-- time on terminal platforms before departure, kept on its own and not part of the delay; it
-- includes the negative holds as recorded, which terminal_hold_negative_* also shows on their own.

with daily as (

    select
        *,
        'all_days' as day_basis
    from {{ ref('mart_train_delay_daily') }}

    union all

    select
        *,
        'weekday' as day_basis
    from {{ ref('mart_train_delay_daily') }}
    where day_type = 'weekday'

),

totals as (

    select
        day_basis,
        count(*) as service_dates,
        min(service_date) as first_service_date,
        max(service_date) as last_service_date,
        sum(runs_observed) as runs_observed,
        sum(runs_compared) as runs_compared,
        sum(trips_compared) as trips_compared,
        sum(actual_run_seconds_sum) as actual_run_seconds_sum,
        sum(scheduled_run_seconds_sum) as scheduled_run_seconds_sum,
        sum(positive_excess_seconds) as positive_excess_seconds,
        sum(net_excess_seconds) as net_excess_seconds,
        sum(long_runs) as long_runs,
        sum(long_run_positive_excess_seconds) as long_run_positive_excess_seconds,
        sum(long_run_net_excess_seconds) as long_run_net_excess_seconds,
        sum(terminal_hold_in_actual_seconds_sum) as terminal_hold_in_actual_seconds_sum,
        sum(terminal_departure_runs) as terminal_departure_runs,
        sum(terminal_hold_runs) as terminal_hold_runs,
        sum(terminal_hold_seconds_sum) as terminal_hold_seconds_sum,
        sum(terminal_hold_negative_runs) as terminal_hold_negative_runs,
        sum(terminal_hold_negative_seconds_sum) as terminal_hold_negative_seconds_sum,
        sum(terminal_hold_positive_seconds_sum) as terminal_hold_positive_seconds_sum,
        sum(runs_actual_missing) as runs_actual_missing,
        sum(runs_scheduled_missing) as runs_scheduled_missing,
        sum(runs_actual_not_positive) as runs_actual_not_positive,
        sum(actual_not_positive_net_seconds) as actual_not_positive_net_seconds,
        sum(runs_scheduled_not_positive) as runs_scheduled_not_positive,
        sum(scheduled_not_positive_net_seconds) as scheduled_not_positive_net_seconds
    from daily
    group by day_basis

)

select
    cast(day_basis as varchar) as day_basis,
    cast(service_dates as integer) as service_dates,
    cast(first_service_date as date) as first_service_date,
    cast(last_service_date as date) as last_service_date,
    cast(runs_observed as bigint) as runs_observed,
    cast(runs_compared as bigint) as runs_compared,
    cast(trips_compared as bigint) as trips_compared,
    cast(actual_run_seconds_sum as bigint) as actual_run_seconds_sum,
    cast(scheduled_run_seconds_sum as bigint) as scheduled_run_seconds_sum,
    cast(positive_excess_seconds as bigint) as positive_excess_seconds,
    cast(net_excess_seconds as bigint) as net_excess_seconds,
    cast(runs_compared / service_dates as double) as avg_daily_runs,
    cast(trips_compared / service_dates as double) as avg_daily_trips,
    cast(positive_excess_seconds / service_dates as double) as avg_daily_positive_excess_seconds,
    cast(net_excess_seconds / service_dates as double) as avg_daily_net_excess_seconds,
    cast(positive_excess_seconds / nullif(runs_compared, 0) as double) as positive_excess_seconds_per_run,
    cast(net_excess_seconds / nullif(runs_compared, 0) as double) as net_excess_seconds_per_run,
    cast(positive_excess_seconds / nullif(trips_compared, 0) as double) as positive_excess_seconds_per_trip,
    cast(net_excess_seconds / nullif(trips_compared, 0) as double) as net_excess_seconds_per_trip,
    cast(long_runs as bigint) as long_runs,
    cast(long_run_positive_excess_seconds as bigint) as long_run_positive_excess_seconds,
    cast(long_run_net_excess_seconds as bigint) as long_run_net_excess_seconds,
    cast(long_run_positive_excess_seconds / service_dates as double) as avg_daily_long_run_positive_excess_seconds,
    cast(long_run_net_excess_seconds / service_dates as double) as avg_daily_long_run_net_excess_seconds,
    cast((positive_excess_seconds - long_run_positive_excess_seconds) / service_dates as double)
        as avg_daily_positive_excess_seconds_excl_long_runs,
    cast((net_excess_seconds - long_run_net_excess_seconds) / service_dates as double)
        as avg_daily_net_excess_seconds_excl_long_runs,
    cast(terminal_hold_in_actual_seconds_sum as bigint) as terminal_hold_in_actual_seconds_sum,
    cast(terminal_departure_runs as bigint) as terminal_departure_runs,
    cast(terminal_hold_runs as bigint) as terminal_hold_runs,
    cast(terminal_hold_seconds_sum as bigint) as terminal_hold_seconds_sum,
    cast(terminal_hold_seconds_sum / service_dates as double) as avg_daily_terminal_hold_seconds,
    cast(terminal_hold_negative_runs as bigint) as terminal_hold_negative_runs,
    cast(terminal_hold_negative_seconds_sum as bigint) as terminal_hold_negative_seconds_sum,
    cast(terminal_hold_positive_seconds_sum as bigint) as terminal_hold_positive_seconds_sum,
    cast(terminal_hold_negative_seconds_sum / service_dates as double) as avg_daily_terminal_hold_negative_seconds,
    cast(terminal_hold_positive_seconds_sum / service_dates as double) as avg_daily_terminal_hold_positive_seconds,
    cast(runs_actual_missing as bigint) as runs_actual_missing,
    cast(runs_scheduled_missing as bigint) as runs_scheduled_missing,
    cast(runs_actual_not_positive as bigint) as runs_actual_not_positive,
    cast(actual_not_positive_net_seconds as bigint) as actual_not_positive_net_seconds,
    cast(runs_scheduled_not_positive as bigint) as runs_scheduled_not_positive,
    cast(scheduled_not_positive_net_seconds as bigint) as scheduled_not_positive_net_seconds
from totals
