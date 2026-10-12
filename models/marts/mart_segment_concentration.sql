-- Grain: one row per track segment (dim_segments) that has compared runs in the loaded window.
-- Terminal hold distribution (fct_segment_traversals, runs with a recorded hold, as recorded,
-- negative holds included): median, p90 (quantile_cont) and mean seconds per run.
-- Worst window: every run of var('worst_window_days') consecutive calendar days that starts on a
-- loaded service date and ends on or before the last one (mart_train_delay_daily). For each, the segment's positive
-- excess (train delay) and compared runs in the window over its totals for the whole loaded
-- window. The worst window has the largest share of delay (ties: earliest start). Segments with
-- no train delay at all have no worst window (nulls).

with traversals as (

    select * from {{ ref('fct_segment_traversals') }}

),

segment_days as (

    select * from {{ ref('mart_segment_daily') }}

),

loaded_dates as (

    select distinct service_date
    from {{ ref('mart_train_delay_daily') }}

),

last_loaded as (

    select max(service_date) as last_date
    from loaded_dates

),

holds as (

    select
        segment_id,
        count(terminal_hold_seconds) as terminal_hold_runs,
        quantile_cont(terminal_hold_seconds, 0.5) as terminal_hold_median_seconds,
        quantile_cont(terminal_hold_seconds, 0.9) as terminal_hold_p90_seconds,
        avg(terminal_hold_seconds) as terminal_hold_mean_seconds
    from traversals
    where terminal_hold_seconds is not null
    group by segment_id

),

totals as (

    select
        segment_id,
        sum(positive_excess_seconds_sum) as positive_excess_seconds_sum,
        sum(traversals) as traversals
    from segment_days
    group by segment_id

),

window_starts as (

    select loaded_dates.service_date as window_start_date
    from loaded_dates
    cross join last_loaded
    where
        loaded_dates.service_date + interval ({{ var('worst_window_days') }} - 1) day
        <= last_loaded.last_date

),

windows as (

    select
        segment_days.segment_id,
        window_starts.window_start_date,
        sum(segment_days.positive_excess_seconds_sum) as window_positive_excess_seconds_sum,
        sum(segment_days.traversals) as window_traversals
    from segment_days
    inner join window_starts
        on
            segment_days.service_date >= window_starts.window_start_date
            and segment_days.service_date
            < window_starts.window_start_date + interval ({{ var('worst_window_days') }}) day
    group by segment_days.segment_id, window_starts.window_start_date

),

ranked_windows as (

    select
        windows.segment_id,
        windows.window_start_date,
        windows.window_positive_excess_seconds_sum,
        windows.window_traversals,
        row_number() over (
            partition by windows.segment_id
            order by windows.window_positive_excess_seconds_sum desc, windows.window_start_date asc
        ) as window_rank
    from windows
    inner join totals on windows.segment_id = totals.segment_id
    where totals.positive_excess_seconds_sum > 0

),

worst as (

    select
        segment_id,
        window_start_date,
        window_positive_excess_seconds_sum,
        window_traversals
    from ranked_windows
    where window_rank = 1

)

select
    cast(totals.segment_id as varchar) as segment_id,
    cast(totals.traversals as bigint) as traversals,
    cast(totals.positive_excess_seconds_sum as bigint) as positive_excess_seconds_sum,
    cast(coalesce(holds.terminal_hold_runs, 0) as bigint) as terminal_hold_runs,
    cast(holds.terminal_hold_median_seconds as double) as terminal_hold_median_seconds,
    cast(holds.terminal_hold_p90_seconds as double) as terminal_hold_p90_seconds,
    cast(holds.terminal_hold_mean_seconds as double) as terminal_hold_mean_seconds,
    cast({{ var('worst_window_days') }} as integer) as worst_window_days,
    cast(worst.window_start_date as date) as worst_window_start_date,
    cast(
        worst.window_start_date + interval ({{ var('worst_window_days') }} - 1) day as date
    ) as worst_window_end_date,
    cast(worst.window_positive_excess_seconds_sum as bigint) as worst_window_positive_excess_seconds_sum,
    cast(worst.window_traversals as bigint) as worst_window_traversals,
    cast(
        worst.window_positive_excess_seconds_sum / totals.positive_excess_seconds_sum as double
    ) as worst_window_share_of_delay,
    cast(worst.window_traversals / nullif(totals.traversals, 0) as double) as worst_window_share_of_runs
from totals
left join holds on totals.segment_id = holds.segment_id
left join worst on totals.segment_id = worst.segment_id
