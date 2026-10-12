-- Grain: one row per track segment (dim_segments) over the loaded LAMP window.
-- Measured train delay on the segment, exact seconds (fct_segment_traversals, compared runs,
-- runs over 30 minutes included and also counted in long_run_*):
--   positive excess = max(actual - scheduled, 0) per run; net excess = actual - scheduled.
--   avg_weekday_positive_excess_seconds = positive excess summed over weekday runs / weekdays
--     loaded (train-seconds over schedule on an average weekday). The same for net and for
--     all days (avg_daily_*). Every segment uses the same number of dates, from
--     mart_train_delay_daily.
-- Rank: loss_rank orders segments by avg_weekday_positive_excess_seconds, highest first (ties
-- by segment_id); is_top_10 = rank 1 to 10; share_of_segment_train_delay = the segment's value
-- / the sum over all segments. Riders play no part in the rank.
-- Terminals: is_terminal_departure / is_terminal_arrival from dim_segments. terminal_hold_* is
-- the recorded time on the terminal platform before departure (runs of branches that start
-- there). It is not in the excess: on a terminal departure the excess is in-motion time minus
-- scheduled run time (terminal_hold_in_actual_seconds_sum is the hold that LAMP's
-- arrival-to-arrival time included and int_train_runs split out). For terminal
-- arrivals LAMP has no timestamp for holding outside the terminal, so it stays in the run time
-- (terminal_time_split = 'arrival_not_split'). Holds are as recorded: terminal_hold_negative_runs
-- counts runs where LAMP has the departure before the arrival; their seconds are in
-- terminal_hold_seconds_sum and avg_weekday_terminal_hold_seconds and also shown on their own in
-- terminal_hold_negative_seconds_sum and avg_weekday_terminal_hold_negative_seconds.
-- Riders: start_station_avg_weekday_entries = people entering the start station on this line
-- through fare gates on an average weekday (int_station_period_riders, all periods). It counts
-- entries at that station, not riders on this segment, and is null where the station has no
-- gate data. It is not used in the rank.
-- Buffer time: p90 minus median actual run time over compared runs (the extra time to plan so
-- you arrive on time 9 times out of 10); buffer index = buffer / median. All periods and day
-- types pooled.
-- Schedule or service: on each date with at least var('cause_min_runs_per_day') compared runs,
-- take the segment's average net excess. bias = median of those daily values; variability =
-- their IQR (p75 - p25). 'schedule' if |bias| >= var('cause_dominance_ratio') * IQR
-- (consistently off the schedule: the scheduled time is wrong), 'service' if IQR >= ratio *
-- |bias| (sometimes fine, sometimes not: delivery varies), otherwise 'mixed'. Fewer than
-- var('cause_min_days') such dates gives 'insufficient_data'.

with segments as (

    select * from {{ ref('dim_segments') }}

),

traversals as (

    select * from {{ ref('fct_segment_traversals') }}

),

segment_days as (

    select * from {{ ref('mart_segment_daily') }}

),

window_dates as (

    select
        count(*) as service_dates,
        count(*) filter (where day_type = 'weekday') as weekdays
    from {{ ref('mart_train_delay_daily') }}

),

start_entries as (

    select
        station_id,
        line_id,
        sum(avg_daily_gated_entries) as avg_weekday_entries
    from {{ ref('int_station_period_riders') }}
    where day_type = 'weekday'
    group by station_id, line_id

),

run_stats as (

    select
        segment_id,
        quantile_cont(scheduled_run_seconds, 0.5) as median_scheduled_run_seconds,
        quantile_cont(actual_run_seconds, 0.5) as median_run_seconds,
        quantile_cont(actual_run_seconds, 0.9) as p90_run_seconds
    from traversals
    where is_compared
    group by segment_id

),

day_totals as (

    select
        segment_id,
        sum(runs_observed) as runs_observed,
        sum(traversals) as traversals,
        sum(runs_not_compared) as runs_not_compared,
        count(*) filter (where traversals > 0) as service_dates_observed,
        sum(positive_excess_seconds_sum) as positive_excess_seconds_sum,
        sum(net_excess_seconds_sum) as net_excess_seconds_sum,
        sum(traversals) filter (where day_type = 'weekday') as weekday_runs,
        sum(positive_excess_seconds_sum) filter (where day_type = 'weekday') as weekday_positive_excess_seconds_sum,
        sum(net_excess_seconds_sum) filter (where day_type = 'weekday') as weekday_net_excess_seconds_sum,
        sum(long_runs) as long_runs,
        sum(long_run_positive_excess_seconds_sum) as long_run_positive_excess_seconds_sum,
        sum(long_run_net_excess_seconds_sum) as long_run_net_excess_seconds_sum,
        sum(long_run_positive_excess_seconds_sum) filter (where day_type = 'weekday')
            as weekday_long_run_positive_excess_seconds_sum,
        sum(terminal_hold_runs) as terminal_hold_runs,
        sum(terminal_hold_seconds_sum) as terminal_hold_seconds_sum,
        sum(terminal_hold_negative_runs) as terminal_hold_negative_runs,
        sum(terminal_hold_negative_seconds_sum) as terminal_hold_negative_seconds_sum,
        sum(terminal_hold_seconds_sum) filter (where day_type = 'weekday') as weekday_terminal_hold_seconds_sum,
        sum(terminal_hold_negative_runs) filter (where day_type = 'weekday') as weekday_terminal_hold_negative_runs,
        sum(terminal_hold_negative_seconds_sum) filter (where day_type = 'weekday')
            as weekday_terminal_hold_negative_seconds_sum,
        sum(terminal_hold_in_actual_seconds_sum) as terminal_hold_in_actual_seconds_sum
    from segment_days
    group by segment_id

),

daily_excess as (

    select
        segment_id,
        date_key,
        avg_net_excess_seconds
    from segment_days
    where traversals >= {{ var('cause_min_runs_per_day') }}

),

cause_stats as (

    select
        segment_id,
        count(*) as cause_days,
        quantile_cont(avg_net_excess_seconds, 0.5) as bias_seconds,
        quantile_cont(avg_net_excess_seconds, 0.25) as daily_excess_p25_seconds,
        quantile_cont(avg_net_excess_seconds, 0.75) as daily_excess_p75_seconds
    from daily_excess
    group by segment_id

),

combined as (

    select
        segments.segment_id,
        segments.line_id,
        segments.direction_id,
        segments.from_station_id,
        segments.from_station_name,
        segments.to_station_id,
        segments.to_station_name,
        segments.segment_name,
        segments.is_terminal_departure,
        segments.is_terminal_arrival,
        coalesce(day_totals.runs_observed, 0) as runs_observed,
        coalesce(day_totals.traversals, 0) as traversals,
        coalesce(day_totals.runs_not_compared, 0) as runs_not_compared,
        coalesce(day_totals.service_dates_observed, 0) as service_dates_observed,
        day_totals.positive_excess_seconds_sum,
        day_totals.net_excess_seconds_sum,
        day_totals.positive_excess_seconds_sum / nullif(day_totals.traversals, 0) as avg_positive_excess_seconds,
        day_totals.net_excess_seconds_sum / nullif(day_totals.traversals, 0) as avg_net_excess_seconds,
        coalesce(day_totals.weekday_runs, 0) as weekday_runs,
        coalesce(day_totals.weekday_runs, 0) / nullif(window_dates.weekdays, 0) as avg_weekday_runs,
        case
            when day_totals.weekday_runs > 0
                then day_totals.weekday_positive_excess_seconds_sum / nullif(window_dates.weekdays, 0)
        end as avg_weekday_positive_excess_seconds,
        case
            when day_totals.weekday_runs > 0
                then day_totals.weekday_net_excess_seconds_sum / nullif(window_dates.weekdays, 0)
        end as avg_weekday_net_excess_seconds,
        day_totals.positive_excess_seconds_sum / nullif(window_dates.service_dates, 0)
            as avg_daily_positive_excess_seconds,
        day_totals.net_excess_seconds_sum / nullif(window_dates.service_dates, 0) as avg_daily_net_excess_seconds,
        coalesce(day_totals.long_runs, 0) as long_runs,
        coalesce(day_totals.long_run_positive_excess_seconds_sum, 0) as long_run_positive_excess_seconds_sum,
        coalesce(day_totals.long_run_net_excess_seconds_sum, 0) as long_run_net_excess_seconds_sum,
        coalesce(day_totals.weekday_long_run_positive_excess_seconds_sum, 0) / nullif(window_dates.weekdays, 0)
            as avg_weekday_long_run_positive_excess_seconds,
        case
            when segments.is_terminal_departure then 'departure_hold_split'
            when segments.is_terminal_arrival then 'arrival_not_split'
            else 'not_terminal'
        end as terminal_time_split,
        coalesce(day_totals.terminal_hold_runs, 0) as terminal_hold_runs,
        coalesce(day_totals.terminal_hold_seconds_sum, 0) as terminal_hold_seconds_sum,
        coalesce(day_totals.terminal_hold_negative_runs, 0) as terminal_hold_negative_runs,
        coalesce(day_totals.terminal_hold_negative_seconds_sum, 0) as terminal_hold_negative_seconds_sum,
        coalesce(day_totals.weekday_terminal_hold_negative_runs, 0) as weekday_terminal_hold_negative_runs,
        case
            when day_totals.terminal_hold_runs > 0
                then coalesce(day_totals.weekday_terminal_hold_negative_seconds_sum, 0)
                    / nullif(window_dates.weekdays, 0)
        end as avg_weekday_terminal_hold_negative_seconds,
        coalesce(day_totals.terminal_hold_in_actual_seconds_sum, 0) as terminal_hold_in_actual_seconds_sum,
        day_totals.terminal_hold_seconds_sum / nullif(day_totals.terminal_hold_runs, 0) as avg_terminal_hold_seconds,
        case
            when day_totals.terminal_hold_runs > 0
                then coalesce(day_totals.weekday_terminal_hold_seconds_sum, 0) / nullif(window_dates.weekdays, 0)
        end as avg_weekday_terminal_hold_seconds,
        run_stats.median_scheduled_run_seconds,
        run_stats.median_run_seconds,
        run_stats.p90_run_seconds,
        run_stats.p90_run_seconds - run_stats.median_run_seconds as buffer_seconds,
        (run_stats.p90_run_seconds - run_stats.median_run_seconds) / nullif(run_stats.median_run_seconds, 0)
            as buffer_index,
        start_entries.avg_weekday_entries is not null as start_station_has_gate_data,
        start_entries.avg_weekday_entries as start_station_avg_weekday_entries,
        coalesce(cause_stats.cause_days, 0) as cause_days,
        cause_stats.bias_seconds,
        cause_stats.daily_excess_p25_seconds,
        cause_stats.daily_excess_p75_seconds,
        cause_stats.daily_excess_p75_seconds - cause_stats.daily_excess_p25_seconds as variability_iqr_seconds
    from segments
    cross join window_dates
    left join day_totals on segments.segment_id = day_totals.segment_id
    left join run_stats on segments.segment_id = run_stats.segment_id
    left join cause_stats on segments.segment_id = cause_stats.segment_id
    left join start_entries
        on
            segments.from_station_id = start_entries.station_id
            and segments.line_id = start_entries.line_id

),

ranked as (

    select
        *,
        case
            when avg_weekday_positive_excess_seconds is not null
                then row_number() over (
                        partition by avg_weekday_positive_excess_seconds is not null
                        order by avg_weekday_positive_excess_seconds desc, segment_id asc
                    )
        end as loss_rank,
        avg_weekday_positive_excess_seconds
        / nullif(sum(avg_weekday_positive_excess_seconds) over (), 0) as share_of_segment_train_delay
    from combined

)

select
    cast(segment_id as varchar) as segment_id,
    cast(line_id as varchar) as line_id,
    cast(direction_id as integer) as direction_id,
    cast(from_station_id as varchar) as from_station_id,
    cast(from_station_name as varchar) as from_station_name,
    cast(to_station_id as varchar) as to_station_id,
    cast(to_station_name as varchar) as to_station_name,
    cast(segment_name as varchar) as segment_name,
    cast(is_terminal_departure as boolean) as is_terminal_departure,
    cast(is_terminal_arrival as boolean) as is_terminal_arrival,
    cast(runs_observed as bigint) as runs_observed,
    cast(traversals as bigint) as traversals,
    cast(runs_not_compared as bigint) as runs_not_compared,
    cast(service_dates_observed as integer) as service_dates_observed,
    cast(positive_excess_seconds_sum as bigint) as positive_excess_seconds_sum,
    cast(net_excess_seconds_sum as bigint) as net_excess_seconds_sum,
    cast(avg_positive_excess_seconds as double) as avg_positive_excess_seconds,
    cast(avg_net_excess_seconds as double) as avg_net_excess_seconds,
    cast(weekday_runs as bigint) as weekday_runs,
    cast(avg_weekday_runs as double) as avg_weekday_runs,
    cast(avg_weekday_positive_excess_seconds as double) as avg_weekday_positive_excess_seconds,
    cast(avg_weekday_net_excess_seconds as double) as avg_weekday_net_excess_seconds,
    cast(avg_daily_positive_excess_seconds as double) as avg_daily_positive_excess_seconds,
    cast(avg_daily_net_excess_seconds as double) as avg_daily_net_excess_seconds,
    cast(long_runs as bigint) as long_runs,
    cast(long_run_positive_excess_seconds_sum as bigint) as long_run_positive_excess_seconds_sum,
    cast(long_run_net_excess_seconds_sum as bigint) as long_run_net_excess_seconds_sum,
    cast(avg_weekday_long_run_positive_excess_seconds as double) as avg_weekday_long_run_positive_excess_seconds,
    cast(terminal_time_split as varchar) as terminal_time_split,
    cast(terminal_hold_runs as bigint) as terminal_hold_runs,
    cast(terminal_hold_seconds_sum as bigint) as terminal_hold_seconds_sum,
    cast(terminal_hold_negative_runs as bigint) as terminal_hold_negative_runs,
    cast(terminal_hold_negative_seconds_sum as bigint) as terminal_hold_negative_seconds_sum,
    cast(weekday_terminal_hold_negative_runs as bigint) as weekday_terminal_hold_negative_runs,
    cast(avg_weekday_terminal_hold_negative_seconds as double) as avg_weekday_terminal_hold_negative_seconds,
    cast(terminal_hold_in_actual_seconds_sum as bigint) as terminal_hold_in_actual_seconds_sum,
    cast(avg_terminal_hold_seconds as double) as avg_terminal_hold_seconds,
    cast(avg_weekday_terminal_hold_seconds as double) as avg_weekday_terminal_hold_seconds,
    cast(median_scheduled_run_seconds as double) as median_scheduled_run_seconds,
    cast(median_run_seconds as double) as median_run_seconds,
    cast(p90_run_seconds as double) as p90_run_seconds,
    cast(buffer_seconds as double) as buffer_seconds,
    cast(buffer_index as double) as buffer_index,
    cast(loss_rank as integer) as loss_rank,
    cast(coalesce(loss_rank <= 10, false) as boolean) as is_top_10,
    cast(share_of_segment_train_delay as double) as share_of_segment_train_delay,
    cast(start_station_has_gate_data as boolean) as start_station_has_gate_data,
    cast(start_station_avg_weekday_entries as double) as start_station_avg_weekday_entries,
    cast(cause_days as integer) as cause_days,
    cast(bias_seconds as double) as bias_seconds,
    cast(daily_excess_p25_seconds as double) as daily_excess_p25_seconds,
    cast(daily_excess_p75_seconds as double) as daily_excess_p75_seconds,
    cast(variability_iqr_seconds as double) as variability_iqr_seconds,
    cast(
        case
            when cause_days < {{ var('cause_min_days') }} then 'insufficient_data'
            when abs(bias_seconds) >= {{ var('cause_dominance_ratio') }} * variability_iqr_seconds then 'schedule'
            when variability_iqr_seconds >= {{ var('cause_dominance_ratio') }} * abs(bias_seconds) then 'service'
            else 'mixed'
        end as varchar
    ) as cause_class
from ranked
