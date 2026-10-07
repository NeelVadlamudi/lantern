-- Grain: one row per station, trunk line, service date and service period.
-- Additive counts only (no shares), so a client can filter any date range and re-aggregate:
--   avg excess seconds = sum(excess_travel_seconds_sum) / sum(travel_comparisons)
--   long-gap share     = sum(long_gaps) / sum(headway_observations)

select
    {{ dbt_utils.generate_surrogate_key([
        'station_id', 'line_id', 'service_date', 'service_period_id'
    ]) }} as station_day_period_key,
    cast(station_id as varchar) as station_id,
    cast(line_id as varchar) as line_id,
    cast(service_date as date) as service_date,
    cast(max(date_key) as integer) as date_key,
    cast(service_period_id as varchar) as service_period_id,
    cast(count(*) as bigint) as trip_stop_events,
    cast(count(*) filter (where has_travel_comparison) as bigint) as travel_comparisons,
    cast(coalesce(sum(excess_travel_seconds), 0) as bigint) as excess_travel_seconds_sum,
    cast(count(*) filter (where has_headway_comparison) as bigint) as headway_observations,
    cast(count(*) filter (where is_long_gap) as bigint) as long_gaps,
    cast(count(*) filter (where is_bunched) as bigint) as bunched_headways
from {{ ref('fct_trip_stop_events') }}
group by station_id, line_id, service_date, service_period_id
