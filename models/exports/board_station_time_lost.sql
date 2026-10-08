{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/station_time_lost.parquet'
    )
}}
-- Board file: estimated rider time lost per station, line, day type and service period,
-- averaged per service date of that day type (mart_station_rider_time_lost). Excess wait and
-- excess ride per rider are pooled over the dates (summed headways and segment excess), so
-- they are the same formulas as the daily cells. Rider time lost is per average day of that
-- day type, over the dates with a rider weight. Exact seconds plus labels.
-- Wait is given without the gaps over 1 hour (no suffix) and with the ones that count as
-- passenger waits (*_with_gaps); the gaps are counted in suspension_gap_* and non_wait_gap_*.
-- share_of_total_rider_time_lost = the row's rider time lost (wait + ride) / the sum over all
-- rows of the same day type. Not clamped: a row with net negative time lost has a negative share.

with cells as (

    select * from {{ ref('mart_station_rider_time_lost') }}

),

dates_per_type as (

    select
        day_type,
        count(*) as service_dates
    from {{ ref('mart_rider_time_lost_daily') }}
    where has_rider_data
    group by day_type

),

pooled as (

    select
        station_id,
        line_id,
        day_type,
        service_period_id,
        sum(headway_observations) as headway_observations,
        sum(suspension_gap_count) as suspension_gap_count,
        sum(suspension_gap_seconds) as suspension_gap_seconds,
        sum(waited_gap_count) as waited_gap_count,
        sum(non_wait_gap_count) as non_wait_gap_count,
        sum(non_wait_gap_seconds) as non_wait_gap_seconds,
        (sum(coalesce(actual_headway_squared_sum, 0)) + sum(waited_gap_squared_sum))
        / nullif(2 * (sum(coalesce(actual_headway_seconds_sum, 0)) + sum(waited_gap_seconds)), 0)
            as actual_expected_wait_with_gaps_seconds,
        (sum(coalesce(scheduled_headway_squared_sum, 0)) + sum(waited_gap_scheduled_squared_sum))
        / nullif(2 * (sum(coalesce(scheduled_headway_seconds_sum, 0)) + sum(waited_gap_scheduled_seconds)), 0)
            as scheduled_expected_wait_with_gaps_seconds,
        sum(rider_seconds_lost_with_gaps) as rider_seconds_lost_with_gaps,
        sum(segment_departures) as segment_departures,
        sum(actual_headway_squared_sum) / nullif(2 * sum(actual_headway_seconds_sum), 0)
            as actual_expected_wait_seconds,
        sum(scheduled_headway_squared_sum) / nullif(2 * sum(scheduled_headway_seconds_sum), 0)
            as scheduled_expected_wait_seconds,
        sum(excess_ride_seconds_sum) / nullif(sum(segment_departures), 0) as excess_ride_seconds,
        bool_or(has_rider_data) as has_rider_data,
        max(gated_entries) as gated_entries,
        sum(rider_seconds_lost) as rider_seconds_lost
    from cells
    group by station_id, line_id, day_type, service_period_id

),

averaged as (

    select
        pooled.*,
        pooled.actual_expected_wait_seconds - pooled.scheduled_expected_wait_seconds as excess_wait_seconds,
        pooled.actual_expected_wait_with_gaps_seconds - pooled.scheduled_expected_wait_with_gaps_seconds
            as excess_wait_with_gaps_seconds,
        case
            when pooled.has_rider_data then pooled.rider_seconds_lost / dates_per_type.service_dates
        end as avg_daily_rider_seconds_lost,
        case
            when pooled.has_rider_data then pooled.rider_seconds_lost_with_gaps / dates_per_type.service_dates
        end as avg_daily_rider_seconds_lost_with_gaps,
        case when pooled.has_rider_data then pooled.rider_seconds_lost end
        / sum(case when pooled.has_rider_data then pooled.rider_seconds_lost end) over (partition by pooled.day_type)
            as share_of_total_rider_time_lost,
        case when pooled.has_rider_data then pooled.rider_seconds_lost_with_gaps end
        / sum(case when pooled.has_rider_data then pooled.rider_seconds_lost_with_gaps end)
            over (partition by pooled.day_type)
            as share_of_total_rider_time_lost_with_gaps
    from pooled
    left join dates_per_type on pooled.day_type = dates_per_type.day_type

)

select
    averaged.station_id,
    stations.station_name,
    averaged.line_id,
    averaged.day_type,
    averaged.service_period_id,
    averaged.headway_observations,
    averaged.suspension_gap_count,
    averaged.suspension_gap_seconds,
    {{ format_duration('averaged.suspension_gap_seconds') }} as suspension_gap_label,
    averaged.waited_gap_count,
    averaged.non_wait_gap_count,
    averaged.non_wait_gap_seconds,
    averaged.segment_departures,
    averaged.has_rider_data,
    averaged.gated_entries as avg_daily_gated_entries,
    averaged.actual_expected_wait_seconds,
    {{ format_duration('averaged.actual_expected_wait_seconds') }} as actual_expected_wait_label,
    averaged.scheduled_expected_wait_seconds,
    {{ format_duration('averaged.scheduled_expected_wait_seconds') }} as scheduled_expected_wait_label,
    averaged.excess_wait_seconds,
    {{ format_duration('averaged.excess_wait_seconds') }} as excess_wait_label,
    averaged.excess_ride_seconds,
    {{ format_duration('averaged.excess_ride_seconds') }} as excess_ride_label,
    averaged.avg_daily_rider_seconds_lost as avg_daily_rider_time_lost_seconds,
    {{ format_duration('averaged.avg_daily_rider_seconds_lost') }} as avg_daily_rider_time_lost_label,
    averaged.actual_expected_wait_with_gaps_seconds,
    {{ format_duration('averaged.actual_expected_wait_with_gaps_seconds') }} as actual_expected_wait_with_gaps_label,
    averaged.scheduled_expected_wait_with_gaps_seconds,
    {{ format_duration('averaged.scheduled_expected_wait_with_gaps_seconds') }}
        as scheduled_expected_wait_with_gaps_label,
    averaged.excess_wait_with_gaps_seconds,
    {{ format_duration('averaged.excess_wait_with_gaps_seconds') }} as excess_wait_with_gaps_label,
    averaged.avg_daily_rider_seconds_lost_with_gaps as avg_daily_rider_time_lost_with_gaps_seconds,
    {{ format_duration('averaged.avg_daily_rider_seconds_lost_with_gaps') }}
        as avg_daily_rider_time_lost_with_gaps_label,
    averaged.share_of_total_rider_time_lost,
    averaged.share_of_total_rider_time_lost_with_gaps
from averaged
left join {{ ref('dim_stations') }} as stations on averaged.station_id = stations.station_id
order by averaged.station_id, averaged.line_id, averaged.day_type, averaged.service_period_id
