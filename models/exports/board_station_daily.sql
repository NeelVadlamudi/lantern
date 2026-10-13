{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/station_daily.parquet'
    )
}}
-- Board file: station x line x service date x service period additive counts
-- (mart_station_daily_reliability). Lets the board filter station shading by date range.
-- Sorted by date then station so DuckDB-WASM can skip row groups on date filters.

with daily as (
    select * from {{ ref('mart_station_daily_reliability') }}
),

planned as (
    select * from {{ ref('mart_planned_change_scope_days') }}
    where scope_type = 'line'
),

flagged as (
    select
        daily.*,
        coalesce(planned.is_planned_change, false) as is_planned_change
    from daily
    left join planned on daily.line_id = planned.scope_id and daily.service_date = planned.service_date
)

select
    service_date,
    day_type,
    is_planned_change,
    station_id,
    line_id,
    service_period_id,
    trip_stop_events,
    travel_comparisons,
    excess_travel_seconds_sum,
    headway_observations,
    long_gaps
from flagged
order by service_date, station_id, line_id, service_period_id
