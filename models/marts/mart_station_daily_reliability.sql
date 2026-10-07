-- Grain: one row per station, trunk line, service date and service period.
-- Additive counts only (no shares), so a client can filter any date range and re-aggregate:
--   avg excess seconds = sum(excess_travel_seconds_sum) / sum(travel_comparisons)
--   long-gap share     = sum(long_gaps) / sum(headway_observations)

select
    {{ dbt_utils.generate_surrogate_key([
        'events.station_id', 'events.line_id', 'events.service_date', 'events.service_period_id'
    ]) }} as station_day_period_key,
    cast(events.station_id as varchar) as station_id,
    cast(events.line_id as varchar) as line_id,
    cast(events.service_date as date) as service_date,
    cast(max(events.date_key) as integer) as date_key,
    cast(max(dates.day_type) as varchar) as day_type,
    cast(events.service_period_id as varchar) as service_period_id,
    cast(count(*) as bigint) as trip_stop_events,
    cast(count(*) filter (where events.has_travel_comparison) as bigint) as travel_comparisons,
    cast(coalesce(sum(events.excess_travel_seconds), 0) as bigint) as excess_travel_seconds_sum,
    cast(count(*) filter (where events.has_headway_comparison) as bigint) as headway_observations,
    cast(count(*) filter (where events.is_long_gap) as bigint) as long_gaps,
    cast(count(*) filter (where events.is_bunched) as bigint) as bunched_headways
from {{ ref('fct_trip_stop_events') }} as events
inner join {{ ref('dim_dates') }} as dates
    on events.date_key = dates.date_key
group by events.station_id, events.line_id, events.service_date, events.service_period_id
