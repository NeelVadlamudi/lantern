-- Grain: one row per track segment. "Getting worse": the last var('worse_recent_days')
-- service dates (ending on the latest loaded date) against the var('worse_prior_days') dates
-- before them.
--   delta_excess_seconds = average excess run time per train run, recent minus prior.
--   loss share = the segment's average daily rider-weighted loss as a share of the positive
--     losses of all segments in the same window; share_change = recent share - prior share.
--   is_getting_worse = clears the volume threshold (at least var('worse_min_volume_recent')
--     runs in the recent window and var('worse_min_volume_prior') in the prior window, about
--     21 a day; below that a few odd days move the average), the delta is at least
--     var('worse_min_delta_seconds') (5 s), and it is at least 5 s above the typical delta
--     (typical_delta_excess_seconds: the median delta of the rows that clear the volume
--     threshold). The whole system can get slower at once; the flag picks out the ones that
--     got worse by more than the rest.

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
    from {{ ref('mart_rider_time_lost_daily') }}

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

window_dates as (

    select
        count(*) filter (where daily.has_rider_data and daily.service_date >= bounds.recent_start_date)
            as recent_dates_with_riders,
        count(*) filter (
            where
            daily.has_rider_data
            and daily.service_date >= bounds.prior_start_date
            and daily.service_date < bounds.recent_start_date
        ) as prior_dates_with_riders
    from {{ ref('mart_rider_time_lost_daily') }} as daily
    cross join bounds

),

per_segment as (

    select
        segment_id,
        coalesce(sum(traversals) filter (where trend_window = 'recent'), 0) as runs_recent,
        coalesce(sum(traversals) filter (where trend_window = 'prior'), 0) as runs_prior,
        sum(excess_travel_seconds_sum) filter (where trend_window = 'recent')
        / sum(traversals) filter (where trend_window = 'recent') as avg_excess_seconds_recent,
        sum(excess_travel_seconds_sum) filter (where trend_window = 'prior')
        / sum(traversals) filter (where trend_window = 'prior') as avg_excess_seconds_prior,
        bool_or(has_rider_data) filter (where trend_window = 'recent') as has_riders_recent,
        bool_or(has_rider_data) filter (where trend_window = 'prior') as has_riders_prior,
        sum(rider_seconds_lost) filter (where trend_window = 'recent') as rider_seconds_lost_recent,
        sum(rider_seconds_lost) filter (where trend_window = 'prior') as rider_seconds_lost_prior
    from windowed
    where trend_window is not null
    group by segment_id

),

averaged as (

    select
        segments.*,
        coalesce(per_segment.runs_recent, 0) as runs_recent,
        coalesce(per_segment.runs_prior, 0) as runs_prior,
        per_segment.avg_excess_seconds_recent,
        per_segment.avg_excess_seconds_prior,
        case
            when per_segment.has_riders_recent
                then per_segment.rider_seconds_lost_recent / nullif(window_dates.recent_dates_with_riders, 0)
        end as avg_daily_rider_seconds_lost_recent,
        case
            when per_segment.has_riders_prior
                then per_segment.rider_seconds_lost_prior / nullif(window_dates.prior_dates_with_riders, 0)
        end as avg_daily_rider_seconds_lost_prior
    from segments
    cross join window_dates
    left join per_segment on segments.segment_id = per_segment.segment_id

),

shared as (

    select
        *,
        avg_daily_rider_seconds_lost_recent
        / nullif(sum(greatest(avg_daily_rider_seconds_lost_recent, 0)) over (), 0) as loss_share_recent,
        avg_daily_rider_seconds_lost_prior
        / nullif(sum(greatest(avg_daily_rider_seconds_lost_prior, 0)) over (), 0) as loss_share_prior
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
    cast(shared.runs_recent as bigint) as runs_recent,
    cast(shared.runs_prior as bigint) as runs_prior,
    cast(shared.avg_excess_seconds_recent as double) as avg_excess_seconds_recent,
    cast(shared.avg_excess_seconds_prior as double) as avg_excess_seconds_prior,
    cast(shared.avg_excess_seconds_recent - shared.avg_excess_seconds_prior as double) as delta_excess_seconds,
    cast(shared.avg_daily_rider_seconds_lost_recent as double) as avg_daily_rider_seconds_lost_recent,
    cast(shared.avg_daily_rider_seconds_lost_prior as double) as avg_daily_rider_seconds_lost_prior,
    cast(
        shared.avg_daily_rider_seconds_lost_recent - shared.avg_daily_rider_seconds_lost_prior as double
    ) as delta_daily_rider_seconds_lost,
    cast(shared.loss_share_recent as double) as loss_share_recent,
    cast(shared.loss_share_prior as double) as loss_share_prior,
    cast(shared.loss_share_recent - shared.loss_share_prior as double) as loss_share_change,
    cast(
        shared.runs_recent >= {{ var('worse_min_volume_recent') }}
        and shared.runs_prior >= {{ var('worse_min_volume_prior') }}
        as boolean
    ) as meets_volume_threshold,
    cast(typical.typical_delta_excess_seconds as double) as typical_delta_excess_seconds,
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
cross join typical
