-- Grain: one row per track segment. "Getting worse": the last var('worse_recent_days')
-- service dates (ending on the latest loaded date) against the var('worse_prior_days') dates
-- before them. Every raw value behind the flag is a column, for every row:
--   runs_*, positive_excess_seconds_sum_*, net_excess_seconds_sum_*  compared runs and their
--     summed excess in each window (exact seconds; runs over 30 minutes included)
--   avg_excess_seconds_* = net excess per run (net sum / runs); delta_excess_seconds = recent -
--     prior. avg_positive_excess_seconds_* and delta_positive_excess_seconds: the same, positive only.
--   avg_daily_positive_excess_seconds_* = positive excess per service date of the window (train
--     delay per day); delay_share_* = that value as a share of the sum over all segments;
--     delay_share_change = recent - prior.
--   is_getting_worse = clears the volume threshold (at least var('worse_min_volume_recent')
--     runs in the recent window and var('worse_min_volume_prior') in the prior window, about
--     21 a day; below that a few odd days move the average), delta_excess_seconds is at least
--     var('worse_min_delta_seconds') (5 s), and it is at least 5 s above the typical delta
--     (typical_delta_excess_seconds: the median delta of the rows that clear the volume
--     threshold). The whole system can get slower at once; the flag picks out the ones that
--     got worse by more than the rest. The flag is a rule on top of the values; it changes
--     nothing in them.

with segment_days as (

    select * from {{ ref('mart_segment_daily') }}

),

segments as (

    select
        segment_id,
        line_id,
        direction_id,
        from_station_id,
        to_station_id,
        segment_name
    from {{ ref('dim_segments') }}

),

bounds as (

    select
        max(service_date) as recent_end_date,
        max(service_date) - {{ var('worse_recent_days') }} + 1 as recent_start_date,
        max(service_date) - {{ var('worse_recent_days') }} - {{ var('worse_prior_days') }} + 1 as prior_start_date
    from {{ ref('mart_train_delay_daily') }}

),

window_dates as (

    select
        count(*) filter (where daily.service_date >= bounds.recent_start_date) as recent_dates,
        count(*) filter (
            where
            daily.service_date >= bounds.prior_start_date
            and daily.service_date < bounds.recent_start_date
        ) as prior_dates
    from {{ ref('mart_train_delay_daily') }} as daily
    cross join bounds

),

windowed as (

    select
        segment_days.*,
        case
            when segment_days.service_date >= bounds.recent_start_date then 'recent'
            when segment_days.service_date >= bounds.prior_start_date then 'prior'
        end as trend_window
    from segment_days
    cross join bounds

),

per_segment as (

    select
        segment_id,
        sum(traversals) filter (where trend_window = 'recent') as runs_recent,
        sum(traversals) filter (where trend_window = 'prior') as runs_prior,
        sum(positive_excess_seconds_sum) filter (where trend_window = 'recent') as positive_sum_recent,
        sum(positive_excess_seconds_sum) filter (where trend_window = 'prior') as positive_sum_prior,
        sum(net_excess_seconds_sum) filter (where trend_window = 'recent') as net_sum_recent,
        sum(net_excess_seconds_sum) filter (where trend_window = 'prior') as net_sum_prior
    from windowed
    where trend_window is not null
    group by segment_id

),

averaged as (

    select
        segments.*,
        coalesce(per_segment.runs_recent, 0) as runs_recent,
        coalesce(per_segment.runs_prior, 0) as runs_prior,
        coalesce(per_segment.positive_sum_recent, 0) as positive_sum_recent,
        coalesce(per_segment.positive_sum_prior, 0) as positive_sum_prior,
        coalesce(per_segment.net_sum_recent, 0) as net_sum_recent,
        coalesce(per_segment.net_sum_prior, 0) as net_sum_prior,
        per_segment.net_sum_recent / nullif(per_segment.runs_recent, 0) as avg_excess_seconds_recent,
        per_segment.net_sum_prior / nullif(per_segment.runs_prior, 0) as avg_excess_seconds_prior,
        per_segment.positive_sum_recent / nullif(per_segment.runs_recent, 0) as avg_positive_excess_seconds_recent,
        per_segment.positive_sum_prior / nullif(per_segment.runs_prior, 0) as avg_positive_excess_seconds_prior,
        coalesce(per_segment.positive_sum_recent, 0) / nullif(window_dates.recent_dates, 0)
            as avg_daily_positive_excess_seconds_recent,
        coalesce(per_segment.positive_sum_prior, 0) / nullif(window_dates.prior_dates, 0)
            as avg_daily_positive_excess_seconds_prior
    from segments
    cross join window_dates
    left join per_segment on segments.segment_id = per_segment.segment_id

),

shared as (

    select
        *,
        avg_daily_positive_excess_seconds_recent
        / nullif(sum(avg_daily_positive_excess_seconds_recent) over (), 0) as delay_share_recent,
        avg_daily_positive_excess_seconds_prior
        / nullif(sum(avg_daily_positive_excess_seconds_prior) over (), 0) as delay_share_prior
    from averaged

),

typical as (

    select quantile_cont(avg_excess_seconds_recent - avg_excess_seconds_prior, 0.5) as typical_delta_excess_seconds
    from shared
    where
        runs_recent >= {{ var('worse_min_volume_recent') }}
        and runs_prior >= {{ var('worse_min_volume_prior') }}

)

select
    cast(shared.segment_id as varchar) as segment_id,
    cast(shared.line_id as varchar) as line_id,
    cast(shared.direction_id as integer) as direction_id,
    cast(shared.from_station_id as varchar) as from_station_id,
    cast(shared.to_station_id as varchar) as to_station_id,
    cast(shared.segment_name as varchar) as segment_name,
    cast(bounds.prior_start_date as date) as prior_start_date,
    cast(bounds.recent_start_date - 1 as date) as prior_end_date,
    cast(bounds.recent_start_date as date) as recent_start_date,
    cast(bounds.recent_end_date as date) as recent_end_date,
    cast(window_dates.recent_dates as integer) as recent_dates,
    cast(window_dates.prior_dates as integer) as prior_dates,
    cast(shared.runs_recent as bigint) as runs_recent,
    cast(shared.runs_prior as bigint) as runs_prior,
    cast(shared.positive_sum_recent as bigint) as positive_excess_seconds_sum_recent,
    cast(shared.positive_sum_prior as bigint) as positive_excess_seconds_sum_prior,
    cast(shared.net_sum_recent as bigint) as net_excess_seconds_sum_recent,
    cast(shared.net_sum_prior as bigint) as net_excess_seconds_sum_prior,
    cast(shared.avg_excess_seconds_recent as double) as avg_excess_seconds_recent,
    cast(shared.avg_excess_seconds_prior as double) as avg_excess_seconds_prior,
    cast(shared.avg_excess_seconds_recent - shared.avg_excess_seconds_prior as double) as delta_excess_seconds,
    cast(shared.avg_positive_excess_seconds_recent as double) as avg_positive_excess_seconds_recent,
    cast(shared.avg_positive_excess_seconds_prior as double) as avg_positive_excess_seconds_prior,
    cast(shared.avg_positive_excess_seconds_recent - shared.avg_positive_excess_seconds_prior as double)
        as delta_positive_excess_seconds,
    cast(shared.avg_daily_positive_excess_seconds_recent as double) as avg_daily_positive_excess_seconds_recent,
    cast(shared.avg_daily_positive_excess_seconds_prior as double) as avg_daily_positive_excess_seconds_prior,
    cast(
        shared.avg_daily_positive_excess_seconds_recent - shared.avg_daily_positive_excess_seconds_prior as double
    ) as delta_daily_positive_excess_seconds,
    cast(shared.delay_share_recent as double) as delay_share_recent,
    cast(shared.delay_share_prior as double) as delay_share_prior,
    cast(shared.delay_share_recent - shared.delay_share_prior as double) as delay_share_change,
    cast(
        shared.runs_recent >= {{ var('worse_min_volume_recent') }}
        and shared.runs_prior >= {{ var('worse_min_volume_prior') }}
        as boolean
    ) as meets_volume_threshold,
    cast(typical.typical_delta_excess_seconds as double) as typical_delta_excess_seconds,
    cast(
        shared.avg_excess_seconds_recent - shared.avg_excess_seconds_prior - typical.typical_delta_excess_seconds
        as double
    ) as delta_above_typical_seconds,
    cast(
        coalesce(
            shared.runs_recent >= {{ var('worse_min_volume_recent') }}
            and shared.runs_prior >= {{ var('worse_min_volume_prior') }}
            and shared.avg_excess_seconds_recent - shared.avg_excess_seconds_prior
            >= {{ var('worse_min_delta_seconds') }}
            and shared.avg_excess_seconds_recent - shared.avg_excess_seconds_prior
            >= typical.typical_delta_excess_seconds + {{ var('worse_min_delta_seconds') }},
            false
        ) as boolean
    ) as is_getting_worse
from shared
cross join bounds
cross join window_dates
cross join typical
