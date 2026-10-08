-- Grain: one row per track segment and service date with at least one observed train run.
-- Measured train delay on the segment that day, exact seconds from fct_segment_traversals:
--   positive_excess_seconds_sum = sum of max(actual - scheduled, 0) over compared runs
--   net_excess_seconds_sum      = sum of (actual - scheduled) over compared runs
-- Runs over var('travel_outlier_seconds') (30 min) are included and counted in long_run_*.
-- Runs that could not be compared are counted in runs_not_compared.
-- Terminal departures: terminal_hold_* is the recorded time on the terminal platform before
-- leaving, kept out of the excess (the excess on a terminal departure is in-motion time minus
-- scheduled); terminal_hold_in_actual_seconds_sum is the part of it that was inside
-- actual_run_seconds and was split out (int_train_runs). terminal_hold_negative_runs counts holds where LAMP
-- records the departure before the arrival (a timestamp problem); they are kept as recorded.
-- No rider weighting here.

with traversals as (

    select * from {{ ref('fct_segment_traversals') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['segment_id', 'date_key']) }} as segment_day_key,
    cast(segment_id as varchar) as segment_id,
    cast(line_id as varchar) as line_id,
    cast(service_date as date) as service_date,
    cast(date_key as integer) as date_key,
    cast(day_type as varchar) as day_type,
    cast(count(*) as bigint) as runs_observed,
    cast(count(*) filter (where is_compared) as bigint) as traversals,
    cast(count(*) filter (where not is_compared) as bigint) as runs_not_compared,
    cast(coalesce(sum(positive_excess_seconds), 0) as bigint) as positive_excess_seconds_sum,
    cast(coalesce(sum(net_excess_seconds), 0) as bigint) as net_excess_seconds_sum,
    cast(avg(positive_excess_seconds) as double) as avg_positive_excess_seconds,
    cast(avg(net_excess_seconds) as double) as avg_net_excess_seconds,
    cast(count(*) filter (where is_long_run) as bigint) as long_runs,
    cast(coalesce(sum(positive_excess_seconds) filter (where is_long_run), 0) as bigint)
        as long_run_positive_excess_seconds_sum,
    cast(coalesce(sum(net_excess_seconds) filter (where is_long_run), 0) as bigint)
        as long_run_net_excess_seconds_sum,
    cast(count(terminal_hold_seconds) as bigint) as terminal_hold_runs,
    cast(coalesce(sum(terminal_hold_seconds), 0) as bigint) as terminal_hold_seconds_sum,
    cast(count(*) filter (where terminal_hold_seconds < 0) as bigint) as terminal_hold_negative_runs,
    cast(coalesce(sum(terminal_hold_in_actual_seconds), 0) as bigint) as terminal_hold_in_actual_seconds_sum
from traversals
group by segment_id, line_id, service_date, date_key, day_type
