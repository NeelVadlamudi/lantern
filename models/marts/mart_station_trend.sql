-- Grain: one row per station and line. "Getting worse" for stations: the last
-- var('worse_recent_days') service dates against the var('worse_prior_days') dates before them.
--   excess per rider = excess wait + excess ride (see mart_station_rider_time_lost), pooled
--     over each window: wait from the summed headways (sum(h^2) / (2 * sum(h)), actual minus
--     scheduled), ride from the summed segment excess / segment departures. It does not need
--     gate data, so ungated stations have it too.
--   delta_excess_seconds = excess per rider, recent minus prior.
--   loss share = the station-line's average daily rider time lost as a share of the positive
--     losses of all station-lines in the same window; share_change = recent - prior.
--   is_getting_worse = clears the volume threshold (at least var('worse_min_volume_recent')
--     departures in the recent window and var('worse_min_volume_prior') in the prior window, about
--     21 a day; below that a few odd days move the average), the delta is at least
--     var('worse_min_delta_seconds') (5 s), and it is at least 5 s above the typical delta
--     (typical_delta_excess_seconds: the median delta of the rows that clear the volume
--     threshold). The whole system can get slower at once; the flag picks out the ones that
--     got worse by more than the rest. The flag uses gaps of 1 hour or less; the same values
--     with the gaps over 1 hour that count as waits are in the *_with_gaps columns, and every
--     raw value (wait and ride parts, departures, gap counts, deltas) is a column on every row.

with cells as (

    select * from {{ ref('mart_station_rider_time_lost') }}

),

stations as (

    select
        station_id,
        station_name
    from {{ ref('dim_stations') }}

),

bounds as (

    select
        max(service_date) as recent_end_date,
        max(service_date) - {{ var('worse_recent_days') }} + 1 as recent_start_date,
        max(service_date) - {{ var('worse_recent_days') }} - {{ var('worse_prior_days') }} + 1 as prior_start_date
    from {{ ref('mart_rider_time_lost_daily') }}

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

windowed as (

    select
        cells.*,
        case
            when cells.service_date >= bounds.recent_start_date then 'recent'
            when cells.service_date >= bounds.prior_start_date then 'prior'
        end as trend_window
    from cells
    cross join bounds

),

pooled as (

    select
        station_id,
        line_id,
        trend_window,
        sum(headway_observations) as headway_observations,
        sum(segment_departures) as segment_departures,
        sum(suspension_gap_count) as suspension_gap_count,
        sum(suspension_gap_seconds) as suspension_gap_seconds,
        sum(non_wait_gap_count) as non_wait_gap_count,
        sum(actual_headway_squared_sum) / nullif(2 * sum(actual_headway_seconds_sum), 0)
        - sum(scheduled_headway_squared_sum) / nullif(2 * sum(scheduled_headway_seconds_sum), 0)
            as excess_wait_seconds,
        (sum(coalesce(actual_headway_squared_sum, 0)) + sum(waited_gap_squared_sum))
        / nullif(2 * (sum(coalesce(actual_headway_seconds_sum, 0)) + sum(waited_gap_seconds)), 0)
        - (sum(coalesce(scheduled_headway_squared_sum, 0)) + sum(waited_gap_scheduled_squared_sum))
        / nullif(2 * (sum(coalesce(scheduled_headway_seconds_sum, 0)) + sum(waited_gap_scheduled_seconds)), 0)
            as excess_wait_with_gaps_seconds,
        sum(excess_ride_seconds_sum) / nullif(sum(segment_departures), 0) as excess_ride_seconds,
        bool_or(has_rider_data) as has_rider_data,
        sum(rider_seconds_lost) as rider_seconds_lost,
        sum(rider_seconds_lost_with_gaps) as rider_seconds_lost_with_gaps
    from windowed
    where trend_window is not null
    group by station_id, line_id, trend_window

),

per_station as (

    select
        recent_or_prior.station_id,
        recent_or_prior.line_id,
        coalesce(max(recent_or_prior.headway_observations) filter (where recent_or_prior.trend_window = 'recent'), 0)
            as departures_recent,
        coalesce(max(recent_or_prior.headway_observations) filter (where recent_or_prior.trend_window = 'prior'), 0)
            as departures_prior,
        coalesce(max(recent_or_prior.segment_departures) filter (where recent_or_prior.trend_window = 'recent'), 0)
            as segment_departures_recent,
        coalesce(max(recent_or_prior.segment_departures) filter (where recent_or_prior.trend_window = 'prior'), 0)
            as segment_departures_prior,
        coalesce(max(recent_or_prior.suspension_gap_count) filter (where recent_or_prior.trend_window = 'recent'), 0)
            as suspension_gap_count_recent,
        coalesce(max(recent_or_prior.suspension_gap_count) filter (where recent_or_prior.trend_window = 'prior'), 0)
            as suspension_gap_count_prior,
        coalesce(max(recent_or_prior.suspension_gap_seconds) filter (where recent_or_prior.trend_window = 'recent'), 0)
            as suspension_gap_seconds_recent,
        coalesce(max(recent_or_prior.suspension_gap_seconds) filter (where recent_or_prior.trend_window = 'prior'), 0)
            as suspension_gap_seconds_prior,
        max(recent_or_prior.excess_wait_seconds) filter (where recent_or_prior.trend_window = 'recent')
            as excess_wait_seconds_recent,
        max(recent_or_prior.excess_wait_seconds) filter (where recent_or_prior.trend_window = 'prior')
            as excess_wait_seconds_prior,
        max(recent_or_prior.excess_wait_with_gaps_seconds) filter (where recent_or_prior.trend_window = 'recent')
            as excess_wait_with_gaps_seconds_recent,
        max(recent_or_prior.excess_wait_with_gaps_seconds) filter (where recent_or_prior.trend_window = 'prior')
            as excess_wait_with_gaps_seconds_prior,
        max(recent_or_prior.excess_ride_seconds) filter (where recent_or_prior.trend_window = 'recent')
            as excess_ride_seconds_recent,
        max(recent_or_prior.excess_ride_seconds) filter (where recent_or_prior.trend_window = 'prior')
            as excess_ride_seconds_prior,
        max(coalesce(recent_or_prior.excess_wait_seconds, 0) + coalesce(recent_or_prior.excess_ride_seconds, 0))
        filter (where recent_or_prior.trend_window = 'recent') as excess_seconds_per_rider_recent,
        max(coalesce(recent_or_prior.excess_wait_seconds, 0) + coalesce(recent_or_prior.excess_ride_seconds, 0))
        filter (where recent_or_prior.trend_window = 'prior') as excess_seconds_per_rider_prior,
        max(
            coalesce(recent_or_prior.excess_wait_with_gaps_seconds, 0)
            + coalesce(recent_or_prior.excess_ride_seconds, 0)
        ) filter (where recent_or_prior.trend_window = 'recent') as excess_seconds_per_rider_with_gaps_recent,
        max(
            coalesce(recent_or_prior.excess_wait_with_gaps_seconds, 0)
            + coalesce(recent_or_prior.excess_ride_seconds, 0)
        ) filter (where recent_or_prior.trend_window = 'prior') as excess_seconds_per_rider_with_gaps_prior,
        max(
            case when recent_or_prior.has_rider_data then recent_or_prior.rider_seconds_lost end
        ) filter (where recent_or_prior.trend_window = 'recent')
        / nullif(max(window_dates.recent_dates_with_riders), 0) as avg_daily_rider_seconds_lost_recent,
        max(
            case when recent_or_prior.has_rider_data then recent_or_prior.rider_seconds_lost end
        ) filter (where recent_or_prior.trend_window = 'prior')
        / nullif(max(window_dates.prior_dates_with_riders), 0) as avg_daily_rider_seconds_lost_prior,
        max(
            case when recent_or_prior.has_rider_data then recent_or_prior.rider_seconds_lost_with_gaps end
        ) filter (where recent_or_prior.trend_window = 'recent')
        / nullif(max(window_dates.recent_dates_with_riders), 0) as avg_daily_rider_seconds_lost_with_gaps_recent,
        max(
            case when recent_or_prior.has_rider_data then recent_or_prior.rider_seconds_lost_with_gaps end
        ) filter (where recent_or_prior.trend_window = 'prior')
        / nullif(max(window_dates.prior_dates_with_riders), 0) as avg_daily_rider_seconds_lost_with_gaps_prior
    from pooled as recent_or_prior
    cross join window_dates
    group by recent_or_prior.station_id, recent_or_prior.line_id

),

shared as (

    select
        *,
        avg_daily_rider_seconds_lost_recent
        / nullif(sum(greatest(avg_daily_rider_seconds_lost_recent, 0)) over (), 0) as loss_share_recent,
        avg_daily_rider_seconds_lost_prior
        / nullif(sum(greatest(avg_daily_rider_seconds_lost_prior, 0)) over (), 0) as loss_share_prior
    from per_station

),

typical as (

    select
        quantile_cont(excess_seconds_per_rider_recent - excess_seconds_per_rider_prior, 0.5)
            as typical_delta_excess_seconds
    from shared
    where
        departures_recent >= {{ var('worse_min_volume_recent') }}
        and departures_prior >= {{ var('worse_min_volume_prior') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['shared.station_id', 'shared.line_id']) }} as station_line_key,
    cast(shared.station_id as varchar) as station_id,
    cast(stations.station_name as varchar) as station_name,
    cast(shared.line_id as varchar) as line_id,
    cast(bounds.prior_start_date as date) as prior_start_date,
    cast(bounds.recent_start_date - 1 as date) as prior_end_date,
    cast(bounds.recent_start_date as date) as recent_start_date,
    cast(bounds.recent_end_date as date) as recent_end_date,
    cast(shared.departures_recent as bigint) as departures_recent,
    cast(shared.departures_prior as bigint) as departures_prior,
    cast(shared.segment_departures_recent as bigint) as segment_departures_recent,
    cast(shared.segment_departures_prior as bigint) as segment_departures_prior,
    cast(shared.suspension_gap_count_recent as bigint) as suspension_gap_count_recent,
    cast(shared.suspension_gap_count_prior as bigint) as suspension_gap_count_prior,
    cast(shared.suspension_gap_seconds_recent as double) as suspension_gap_seconds_recent,
    cast(shared.suspension_gap_seconds_prior as double) as suspension_gap_seconds_prior,
    cast(shared.excess_wait_seconds_recent as double) as excess_wait_seconds_recent,
    cast(shared.excess_wait_seconds_prior as double) as excess_wait_seconds_prior,
    cast(shared.excess_wait_seconds_recent - shared.excess_wait_seconds_prior as double) as delta_excess_wait_seconds,
    cast(shared.excess_ride_seconds_recent as double) as excess_ride_seconds_recent,
    cast(shared.excess_ride_seconds_prior as double) as excess_ride_seconds_prior,
    cast(shared.excess_ride_seconds_recent - shared.excess_ride_seconds_prior as double) as delta_excess_ride_seconds,
    cast(shared.excess_wait_with_gaps_seconds_recent as double) as excess_wait_with_gaps_seconds_recent,
    cast(shared.excess_wait_with_gaps_seconds_prior as double) as excess_wait_with_gaps_seconds_prior,
    cast(shared.excess_seconds_per_rider_with_gaps_recent as double) as excess_seconds_per_rider_with_gaps_recent,
    cast(shared.excess_seconds_per_rider_with_gaps_prior as double) as excess_seconds_per_rider_with_gaps_prior,
    cast(
        shared.excess_seconds_per_rider_with_gaps_recent - shared.excess_seconds_per_rider_with_gaps_prior as double
    ) as delta_excess_with_gaps_seconds,
    cast(shared.excess_seconds_per_rider_recent as double) as excess_seconds_per_rider_recent,
    cast(shared.excess_seconds_per_rider_prior as double) as excess_seconds_per_rider_prior,
    cast(shared.excess_seconds_per_rider_recent - shared.excess_seconds_per_rider_prior as double)
        as delta_excess_seconds,
    cast(shared.avg_daily_rider_seconds_lost_recent as double) as avg_daily_rider_seconds_lost_recent,
    cast(shared.avg_daily_rider_seconds_lost_prior as double) as avg_daily_rider_seconds_lost_prior,
    cast(
        shared.avg_daily_rider_seconds_lost_recent - shared.avg_daily_rider_seconds_lost_prior as double
    ) as delta_daily_rider_seconds_lost,
    cast(shared.avg_daily_rider_seconds_lost_with_gaps_recent as double)
        as avg_daily_rider_seconds_lost_with_gaps_recent,
    cast(shared.avg_daily_rider_seconds_lost_with_gaps_prior as double) as avg_daily_rider_seconds_lost_with_gaps_prior,
    cast(shared.loss_share_recent as double) as loss_share_recent,
    cast(shared.loss_share_prior as double) as loss_share_prior,
    cast(shared.loss_share_recent - shared.loss_share_prior as double) as loss_share_change,
    cast(
        shared.departures_recent >= {{ var('worse_min_volume_recent') }}
        and shared.departures_prior >= {{ var('worse_min_volume_prior') }}
        as boolean
    ) as meets_volume_threshold,
    cast(typical.typical_delta_excess_seconds as double) as typical_delta_excess_seconds,
    cast(
        shared.excess_seconds_per_rider_recent - shared.excess_seconds_per_rider_prior
        - typical.typical_delta_excess_seconds as double
    ) as delta_above_typical_seconds,
    cast(
        coalesce(
            shared.departures_recent >= {{ var('worse_min_volume_recent') }}
            and shared.departures_prior >= {{ var('worse_min_volume_prior') }}
            and shared.excess_seconds_per_rider_recent - shared.excess_seconds_per_rider_prior
            >= {{ var('worse_min_delta_seconds') }}
            and shared.excess_seconds_per_rider_recent - shared.excess_seconds_per_rider_prior
            >= typical.typical_delta_excess_seconds + {{ var('worse_min_delta_seconds') }},
            false
        ) as boolean
    ) as is_getting_worse
from shared
cross join bounds
cross join typical
left join stations on shared.station_id = stations.station_id
