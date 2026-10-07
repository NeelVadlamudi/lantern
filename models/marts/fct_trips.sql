-- Grain: one row per service date, trip, route and vehicle (one train run).
-- Trip-level schedule comparison over the stop-to-stop segments that could be compared.
-- trip_excess_seconds is the sum of segment excess: how much longer the observed part of the
-- trip took than its schedule. A trip is late when that exceeds var('late_trip_seconds').

with events as (

    select * from {{ ref('fct_trip_stop_events') }}

)

select
    cast(trip_key as varchar) as trip_key,
    cast(max(date_key) as integer) as date_key,
    cast(max(service_date) as date) as service_date,
    cast(max(route_id) as varchar) as route_id,
    cast(max(line_id) as varchar) as line_id,
    cast(max(direction_id) as integer) as direction_id,
    cast(max(trip_id) as varchar) as trip_id,
    cast(max(vehicle_label) as varchar) as vehicle_label,
    cast(bool_or(is_added_trip) as boolean) as is_added_trip,
    cast(min(event_local_at) as timestamp) as first_event_local_at,
    cast(arg_min(service_period_id, event_local_at) as varchar) as start_service_period_id,
    cast(count(*) as bigint) as trip_stop_events,
    cast(count(*) filter (where has_travel_comparison) as bigint) as compared_segments,
    cast(sum(excess_travel_seconds) as bigint) as trip_excess_seconds,
    cast(sum(scheduled_run_seconds) filter (where has_travel_comparison) as bigint) as trip_scheduled_seconds,
    cast(coalesce(sum(excess_travel_seconds) > {{ var('late_trip_seconds') }}, false) as boolean) as is_late_trip
from events
group by trip_key
