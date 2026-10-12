{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/rider_time_lost_daily.parquet'
    )
}}
-- Board file: system-wide estimated rider time lost beyond the schedule per service date
-- (mart_rider_time_lost_daily). Grain: one row per service date. Exact seconds plus labels.
-- *_with_gaps adds the gaps over 1 hour that count as passenger waits; suspension_gap_* counts
-- those gaps (waited + non-wait). gated_entries + gated_entries_no_trains = gated_entries_all_cells:
-- the entries at station, line and period cells with no recorded train that date are kept in
-- their own column (cells_no_trains counts those cells).

select
    service_date,
    day_type,
    is_holiday,
    holiday_name,
    week_start_date,
    has_rider_data,
    gated_entries,
    gated_entries_no_trains,
    gated_entries_all_cells,
    cells_no_trains,
    rider_seconds_lost as rider_time_lost_seconds,
    {{ format_duration('rider_seconds_lost') }} as rider_time_lost_label,
    rider_wait_seconds_lost as rider_wait_time_lost_seconds,
    {{ format_duration('rider_wait_seconds_lost') }} as rider_wait_time_lost_label,
    rider_ride_seconds_lost as rider_ride_time_lost_seconds,
    {{ format_duration('rider_ride_seconds_lost') }} as rider_ride_time_lost_label,
    seconds_lost_per_entry as time_lost_per_entry_seconds,
    {{ format_duration('seconds_lost_per_entry') }} as time_lost_per_entry_label,
    rider_seconds_lost_with_gaps as rider_time_lost_with_gaps_seconds,
    {{ format_duration('rider_seconds_lost_with_gaps') }} as rider_time_lost_with_gaps_label,
    rider_wait_seconds_lost_with_gaps as rider_wait_time_lost_with_gaps_seconds,
    {{ format_duration('rider_wait_seconds_lost_with_gaps') }} as rider_wait_time_lost_with_gaps_label,
    suspension_gap_count,
    suspension_gap_seconds,
    {{ format_duration('suspension_gap_seconds') }} as suspension_gap_label,
    waited_gap_count,
    waited_gap_seconds,
    non_wait_gap_count,
    non_wait_gap_seconds
from {{ ref('mart_rider_time_lost_daily') }}
order by service_date
