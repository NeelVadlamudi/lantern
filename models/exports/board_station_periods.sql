{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/station_periods.parquet'
    )
}}
-- Board file: station x line x day type x period reliability with rider exposure
-- (mart_station_reliability_planned), split on is_planned_change: rows with false leave out
-- days when the line had a planned service change.

select
    station_id,
    line_id,
    day_type,
    service_period_id,
    is_planned_change,
    service_days,
    trip_stop_events,
    round(avg_excess_travel_seconds, 1) as avg_excess_travel_seconds,
    headway_observations,
    round(long_gap_share, 4) as long_gap_share,
    round(headway_adherence_share, 4) as headway_adherence_share,
    median_headway_seconds,
    median_scheduled_headway_seconds,
    has_rider_data,
    round(avg_daily_gated_entries, 1) as avg_daily_gated_entries,
    round(est_window_entries_in_long_gaps, 0) as est_window_entries_in_long_gaps
from {{ ref('mart_station_reliability_planned') }}
order by station_id, line_id, day_type, service_period_id, is_planned_change
