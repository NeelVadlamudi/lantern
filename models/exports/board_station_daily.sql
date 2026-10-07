{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/station_daily.parquet'
    )
}}
-- Board file: station x line x service date x service period additive counts
-- (mart_station_daily_reliability). Lets the board filter station shading by date range.
-- Sorted by date then station so DuckDB-WASM can skip row groups on date filters.

select
    service_date,
    station_id,
    line_id,
    service_period_id,
    trip_stop_events,
    travel_comparisons,
    excess_travel_seconds_sum,
    headway_observations,
    long_gaps
from {{ ref('mart_station_daily_reliability') }}
order by service_date, station_id, line_id, service_period_id
