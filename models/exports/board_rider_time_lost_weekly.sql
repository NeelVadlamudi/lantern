{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/rider_time_lost_weekly.parquet'
    )
}}
-- Board file: weekly trend of estimated rider time lost (mart_rider_time_lost_weekly).
-- Grain: one row per week starting Monday. Exact seconds plus labels.

select
    week_start_date,
    week_end_date,
    first_service_date,
    last_service_date,
    service_dates,
    dates_with_rider_data,
    weekdays_with_rider_data,
    is_complete_week,
    rider_seconds_lost as rider_time_lost_seconds,
    {{ format_duration('rider_seconds_lost') }} as rider_time_lost_label,
    avg_daily_rider_seconds_lost as avg_daily_rider_time_lost_seconds,
    {{ format_duration('avg_daily_rider_seconds_lost') }} as avg_daily_rider_time_lost_label,
    avg_weekday_rider_seconds_lost as avg_weekday_rider_time_lost_seconds,
    {{ format_duration('avg_weekday_rider_seconds_lost') }} as avg_weekday_rider_time_lost_label,
    seconds_lost_per_entry as time_lost_per_entry_seconds,
    {{ format_duration('seconds_lost_per_entry') }} as time_lost_per_entry_label,
    avg_weekday_rider_seconds_lost_with_gaps as avg_weekday_rider_time_lost_with_gaps_seconds,
    {{ format_duration('avg_weekday_rider_seconds_lost_with_gaps') }} as avg_weekday_rider_time_lost_with_gaps_label,
    avg_daily_rider_seconds_lost_with_gaps as avg_daily_rider_time_lost_with_gaps_seconds,
    {{ format_duration('avg_daily_rider_seconds_lost_with_gaps') }} as avg_daily_rider_time_lost_with_gaps_label,
    suspension_gap_count,
    suspension_gap_seconds,
    non_wait_gap_count,
    non_wait_gap_seconds
from {{ ref('mart_rider_time_lost_weekly') }}
order by week_start_date
