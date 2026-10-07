-- LAMP's scheduled travel time between consecutive stops should never be negative.
select
    trip_stop_event_key,
    scheduled_travel_seconds
from {{ ref('stg_lamp__subway_trip_stops') }}
where scheduled_travel_seconds < 0
