-- Grain: one row per service date, trip, route and vehicle (one train run).
-- Trip-level schedule comparison over the stop-to-stop segments that could be compared.
-- trip_excess_seconds is the sum of segment excess: how much longer the observed part of the
-- trip took than its schedule. A trip is late when that exceeds var('late_trip_seconds').
-- Stop-to-stop runs over var('travel_outlier_seconds') (30 minutes, is_travel_outlier) are
-- included like every other compared run. Their part is also given on its own (long_run_*),
-- and the *_excl_long_runs columns give the same measures without them, so
-- trip_excess_seconds = trip_excess_seconds_excl_long_runs + long_run_excess_seconds.
-- is_matched_trip: the trip id is in the GTFS schedule published for the date. Trip measures on
-- the board (late share, average time over schedule) use matched trips; added trips are counted
-- on their own. Duplicate stop events are already removed (fct_trip_stop_events).

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
    cast(bool_or(is_matched_trip) as boolean) as is_matched_trip,
    cast(sum(duplicate_events_dropped) as bigint) as duplicate_events_dropped,
    cast(min(event_local_at) as timestamp) as first_event_local_at,
    cast(arg_min(service_period_id, event_local_at) as varchar) as start_service_period_id,
    cast(count(*) as bigint) as trip_stop_events,
    cast(count(*) filter (where has_travel_comparison) as bigint) as compared_segments,
    cast(sum(excess_travel_seconds) as bigint) as trip_excess_seconds,
    cast(sum(scheduled_run_seconds) filter (where has_travel_comparison) as bigint) as trip_scheduled_seconds,
    cast(coalesce(sum(excess_travel_seconds) > {{ var('late_trip_seconds') }}, false) as boolean) as is_late_trip,
    cast(count(*) filter (where has_travel_comparison and is_travel_outlier) as bigint) as long_run_segments,
    cast(coalesce(sum(excess_travel_seconds) filter (where is_travel_outlier), 0) as bigint)
        as long_run_excess_seconds,
    cast(count(*) filter (where has_travel_comparison and not is_travel_outlier) as bigint)
        as compared_segments_excl_long_runs,
    cast(sum(excess_travel_seconds) filter (where not is_travel_outlier) as bigint)
        as trip_excess_seconds_excl_long_runs,
    cast(sum(scheduled_run_seconds) filter (where has_travel_comparison and not is_travel_outlier) as bigint)
        as trip_scheduled_seconds_excl_long_runs,
    cast(coalesce(
        sum(excess_travel_seconds) filter (where not is_travel_outlier) > {{ var('late_trip_seconds') }},
        false
    ) as boolean) as is_late_trip_excl_long_runs
from events
group by trip_key
