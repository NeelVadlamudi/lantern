-- Grain: one row per track segment (dim_segments) over the loaded LAMP window.
-- Excess travel: actual minus scheduled run time over the segment, per train run.
-- Buffer time: p90 minus median actual run time (the extra time to plan so you arrive on time
-- 9 times out of 10); buffer index = buffer / median. All periods and day types pooled.
-- Rider-weighted loss (an estimate, exact seconds): for each date and service period, the
-- gated entries at the segment's start station times the segment's share of train departures
-- from that station times its average excess run time (mart_segment_daily). Summed
-- over segments this equals the in-vehicle part of rider time lost. Averages divide by the
-- number of service dates (or weekdays) with a rider weight in the window. Segments starting
-- at a station without fare gates have has_rider_data = false and no rank.
-- Rank: by average weekday rider-weighted loss, highest first (ties by segment_id).
-- Schedule or service: on each date with at least var('cause_min_runs_per_day') runs, take the
-- segment's average excess. bias = median of those daily values; variability = their IQR
-- (p75 - p25). 'schedule' if |bias| >= var('cause_dominance_ratio') * IQR (consistently off
-- the schedule: the scheduled time is wrong), 'service' if IQR >= ratio * |bias| (sometimes
-- fine, sometimes not: delivery varies), otherwise 'mixed'. Fewer than var('cause_min_days')
-- such dates gives 'insufficient_data'.

with segments as (

    select * from {{ ref('dim_segments') }}

),

traversals as (

    select * from {{ ref('fct_segment_traversals') }}

),

segment_days as (

    select * from {{ ref('mart_segment_daily') }}

),

rider_dates as (

    select
        count(*) filter (where has_rider_data) as dates_with_rider_data,
        count(*) filter (where has_rider_data and day_type = 'weekday') as weekdays_with_rider_data
    from {{ ref('mart_rider_time_lost_daily') }}

),

run_stats as (

    select
        segment_id,
        count(*) as traversals,
        count(distinct date_key) as service_dates_observed,
        sum(excess_travel_seconds) as excess_travel_seconds_sum,
        avg(excess_travel_seconds) as avg_excess_travel_seconds,
        quantile_cont(scheduled_run_seconds, 0.5) as median_scheduled_run_seconds,
        quantile_cont(actual_run_seconds, 0.5) as median_run_seconds,
        quantile_cont(actual_run_seconds, 0.9) as p90_run_seconds
    from traversals
    group by segment_id

),

rider_loss as (

    select
        segment_id,
        count(*) filter (where has_rider_data) as days_with_riders,
        sum(rider_seconds_lost) as rider_seconds_lost,
        sum(rider_seconds_lost) filter (where day_type = 'weekday') as weekday_rider_seconds_lost
    from segment_days
    group by segment_id

),

daily_excess as (

    select
        segment_id,
        date_key,
        avg_excess_travel_seconds
    from segment_days
    where traversals >= {{ var('cause_min_runs_per_day') }}

),

cause_stats as (

    select
        segment_id,
        count(*) as cause_days,
        quantile_cont(avg_excess_travel_seconds, 0.5) as bias_seconds,
        quantile_cont(avg_excess_travel_seconds, 0.25) as daily_excess_p25_seconds,
        quantile_cont(avg_excess_travel_seconds, 0.75) as daily_excess_p75_seconds
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
        coalesce(run_stats.traversals, 0) as traversals,
        coalesce(run_stats.service_dates_observed, 0) as service_dates_observed,
        run_stats.excess_travel_seconds_sum,
        run_stats.avg_excess_travel_seconds,
        run_stats.median_scheduled_run_seconds,
        run_stats.median_run_seconds,
        run_stats.p90_run_seconds,
        run_stats.p90_run_seconds - run_stats.median_run_seconds as buffer_seconds,
        (run_stats.p90_run_seconds - run_stats.median_run_seconds) / nullif(run_stats.median_run_seconds, 0)
            as buffer_index,
        coalesce(rider_loss.days_with_riders, 0) > 0 as has_rider_data,
        case when rider_loss.days_with_riders > 0 then rider_loss.rider_seconds_lost end as rider_seconds_lost,
        case
            when rider_loss.days_with_riders > 0
                then rider_loss.rider_seconds_lost / nullif(rider_dates.dates_with_rider_data, 0)
        end as avg_daily_rider_seconds_lost,
        case
            when rider_loss.days_with_riders > 0
                then coalesce(rider_loss.weekday_rider_seconds_lost, 0)
                    / nullif(rider_dates.weekdays_with_rider_data, 0)
        end as avg_weekday_rider_seconds_lost,
        coalesce(cause_stats.cause_days, 0) as cause_days,
        cause_stats.bias_seconds,
        cause_stats.daily_excess_p25_seconds,
        cause_stats.daily_excess_p75_seconds,
        cause_stats.daily_excess_p75_seconds - cause_stats.daily_excess_p25_seconds as variability_iqr_seconds
    from segments
    cross join rider_dates
    left join run_stats on segments.segment_id = run_stats.segment_id
    left join rider_loss on segments.segment_id = rider_loss.segment_id
    left join cause_stats on segments.segment_id = cause_stats.segment_id

),

ranked as (

    select
        *,
        case
            when has_rider_data
                then row_number() over (
                        partition by has_rider_data order by avg_weekday_rider_seconds_lost desc, segment_id asc
                    )
        end as loss_rank,
        avg_weekday_rider_seconds_lost
        / nullif(sum(greatest(avg_weekday_rider_seconds_lost, 0)) over (), 0) as share_of_segment_loss
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
    cast(traversals as bigint) as traversals,
    cast(service_dates_observed as integer) as service_dates_observed,
    cast(excess_travel_seconds_sum as bigint) as excess_travel_seconds_sum,
    cast(avg_excess_travel_seconds as double) as avg_excess_travel_seconds,
    cast(median_scheduled_run_seconds as double) as median_scheduled_run_seconds,
    cast(median_run_seconds as double) as median_run_seconds,
    cast(p90_run_seconds as double) as p90_run_seconds,
    cast(buffer_seconds as double) as buffer_seconds,
    cast(buffer_index as double) as buffer_index,
    cast(has_rider_data as boolean) as has_rider_data,
    cast(rider_seconds_lost as double) as rider_seconds_lost,
    cast(avg_daily_rider_seconds_lost as double) as avg_daily_rider_seconds_lost,
    cast(avg_weekday_rider_seconds_lost as double) as avg_weekday_rider_seconds_lost,
    cast(loss_rank as integer) as loss_rank,
    cast(coalesce(loss_rank <= 10, false) as boolean) as is_top_10,
    cast(share_of_segment_loss as double) as share_of_segment_loss,
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
