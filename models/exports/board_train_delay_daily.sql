{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/train_delay_daily.parquet'
    )
}}
-- Board file: measured train delay per service date (mart_train_delay_daily). Grain: one row
-- per service date. Exact seconds plus labels; positive (late time only) and net side by side,
-- runs over 30 minutes and runs that could not be compared counted on their own.

select
    service_date,
    day_type,
    is_holiday,
    runs_observed,
    runs_compared,
    trips_compared,
    positive_excess_seconds as train_delay_seconds,
    {{ format_duration('positive_excess_seconds') }} as train_delay_label,
    net_excess_seconds as train_delay_net_seconds,
    {{ format_duration('net_excess_seconds') }} as train_delay_net_label,
    positive_excess_seconds_per_run as train_delay_per_run_seconds,
    {{ format_duration('positive_excess_seconds_per_run') }} as train_delay_per_run_label,
    net_excess_seconds_per_run as train_delay_net_per_run_seconds,
    {{ format_duration('net_excess_seconds_per_run') }} as train_delay_net_per_run_label,
    long_runs,
    long_run_positive_excess_seconds as long_run_train_delay_seconds,
    {{ format_duration('long_run_positive_excess_seconds') }} as long_run_train_delay_label,
    long_run_net_excess_seconds as long_run_train_delay_net_seconds,
    runs_actual_missing,
    runs_scheduled_missing,
    runs_actual_not_positive,
    actual_not_positive_net_seconds,
    runs_scheduled_not_positive,
    scheduled_not_positive_net_seconds
from {{ ref('mart_train_delay_daily') }}
order by service_date
