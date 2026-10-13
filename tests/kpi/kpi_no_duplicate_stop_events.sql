-- No train set is recorded twice: in fct_trip_stop_events no two events of different trips share
-- the service date, vehicle_label, station and direction within var('duplicate_event_seconds').
-- Every dropped event is accounted for on a kept one, and the trip counts add up: runs that
-- lost every stop event to a matched or longer trip no longer appear in fct_trips.
with events as (
    select
        trip_stop_event_key,
        trip_key,
        service_date,
        vehicle_label,
        station_id,
        direction_id,
        event_local_at
    from {{ ref('fct_trip_stop_events') }}
)

select
    'overlapping events on one train set' as check_name,
    first_event.trip_stop_event_key,
    second_event.trip_stop_event_key as other_event_key
from events as first_event
inner join events as second_event
    on
        first_event.service_date = second_event.service_date
        and first_event.vehicle_label = second_event.vehicle_label
        and first_event.station_id = second_event.station_id
        and first_event.direction_id = second_event.direction_id
        and first_event.trip_key < second_event.trip_key
        and abs(epoch(first_event.event_local_at) - epoch(second_event.event_local_at))
        <= {{ var('duplicate_event_seconds') }}

union all

select
    'kept events do not account for every dropped event' as check_name,
    null as trip_stop_event_key,
    null as other_event_key
from (
    select
        (select count(*) from {{ ref('int_trip_stops__performance') }}) as source_events,
        (select count(*) from {{ ref('fct_trip_stop_events') }}) as kept_events,
        (select sum(duplicate_events_dropped) from {{ ref('fct_trip_stop_events') }}) as dropped_events
) as totals
where totals.source_events != totals.kept_events + totals.dropped_events

union all

select
    'trip counts differ from the events' as check_name,
    null as trip_stop_event_key,
    null as other_event_key
from (
    select
        (select count(distinct trip_key) from {{ ref('fct_trip_stop_events') }}) as event_trips,
        (select count(*) from {{ ref('fct_trips') }}) as fact_trips,
        (
            select sum(duplicate_events_dropped) from {{ ref('fct_trips') }}
        ) as trip_dropped,
        (
            select sum(duplicate_events_dropped) from {{ ref('fct_trip_stop_events') }}
        ) as event_dropped
) as totals
where totals.event_trips != totals.fact_trips or totals.trip_dropped != totals.event_dropped
