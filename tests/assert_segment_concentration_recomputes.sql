-- mart_segment_concentration recomputed straight from fct_segment_traversals: hold median,
-- p90 and mean per segment, and the worst window share found by brute force over every
-- window start. Returns rows that disagree (beyond 1e-9).

with runs as (

    select * from {{ ref('fct_segment_traversals') }}

),

holds as (

    select
        segment_id,
        median(terminal_hold_seconds) as hold_median,
        quantile_cont(terminal_hold_seconds, 0.9) as hold_p90,
        sum(terminal_hold_seconds) / count(terminal_hold_seconds) as hold_mean
    from runs
    group by segment_id

),

loaded_dates as (

    select distinct service_date
    from {{ ref('mart_train_delay_daily') }}

),

last_loaded as (

    select max(service_date) as last_date
    from loaded_dates

),

starts as (

    select loaded_dates.service_date as start_date
    from loaded_dates
    cross join last_loaded
    where loaded_dates.service_date + interval ({{ var('worst_window_days') }} - 1) day <= last_loaded.last_date

),

per_window as (

    select
        runs.segment_id,
        starts.start_date,
        sum(runs.positive_excess_seconds) as window_delay
    from starts
    inner join runs
        on
            runs.is_compared
            and runs.service_date between starts.start_date
            and starts.start_date + interval ({{ var('worst_window_days') }} - 1) day
    group by runs.segment_id, starts.start_date

),

best as (

    select
        segment_id,
        max(window_delay) as window_delay
    from per_window
    group by segment_id

),

total as (

    select
        segment_id,
        sum(positive_excess_seconds) filter (where is_compared) as total_delay
    from runs
    group by segment_id

)

select concentration.segment_id
from {{ ref('mart_segment_concentration') }} as concentration
left join holds on concentration.segment_id = holds.segment_id
left join best on concentration.segment_id = best.segment_id
left join total on concentration.segment_id = total.segment_id
where
    coalesce(
        abs(concentration.terminal_hold_median_seconds - holds.hold_median) > 1e-9,
        concentration.terminal_hold_median_seconds is distinct from holds.hold_median
    )
    or coalesce(
        abs(concentration.terminal_hold_p90_seconds - holds.hold_p90) > 1e-9,
        concentration.terminal_hold_p90_seconds is distinct from holds.hold_p90
    )
    or coalesce(
        abs(concentration.terminal_hold_mean_seconds - holds.hold_mean) > 1e-9,
        concentration.terminal_hold_mean_seconds is distinct from holds.hold_mean
    )
    or (
        total.total_delay > 0
        and abs(concentration.worst_window_share_of_delay - best.window_delay / total.total_delay) > 1e-9
    )
    or concentration.positive_excess_seconds_sum <> total.total_delay
