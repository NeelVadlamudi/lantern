{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/rider_time_lost_daily.parquet'
    )
}}
-- Board file: system-wide estimated rider time lost beyond the schedule per service date
-- (mart_rider_time_lost_daily). Grain: one row per service date. Exact seconds plus labels.

select
    service_date,
    day_type,
    is_holiday,
    holiday_name,
    week_start_date,
    has_rider_data,
    gated_entries,
    rider_seconds_lost as rider_time_lost_seconds,
    {{ format_duration('rider_seconds_lost') }} as rider_time_lost_label,
    rider_wait_seconds_lost as rider_wait_time_lost_seconds,
    {{ format_duration('rider_wait_seconds_lost') }} as rider_wait_time_lost_label,
    rider_ride_seconds_lost as rider_ride_time_lost_seconds,
    {{ format_duration('rider_ride_seconds_lost') }} as rider_ride_time_lost_label,
    seconds_lost_per_entry as time_lost_per_entry_seconds,
    {{ format_duration('seconds_lost_per_entry') }} as time_lost_per_entry_label
from {{ ref('mart_rider_time_lost_daily') }}
order by service_date
