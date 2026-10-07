-- Grain: one row per service date, trip, route, vehicle and stop.
-- LAMP's documented grain is trip-stop per service date, but the raw files carry a small number
-- of repeated trip-stop rows (the same trip id reused on a second branch, or re-reported).
-- Those are deduplicated here; the count is reported in the README.

with source as (

    select * from {{ source('lamp', 'lamp_subway_on_time') }}

),

renamed as (

    select
        cast(strptime(cast(service_date as varchar), '%Y%m%d') as date) as service_date,
        trip_id,
        route_id,
        coalesce(branch_route_id, route_id) as branch_route_id,
        trunk_route_id as line_id,
        cast(direction_id as integer) as direction_id,
        direction,
        direction_destination,
        vehicle_id,
        vehicle_label,
        stop_id,
        parent_station as station_id,
        stop_sequence,
        stop_count,
        start_time as trip_start_seconds,
        to_timestamp(move_timestamp) as moved_at,
        to_timestamp(stop_timestamp) as stopped_at,
        travel_time_seconds,
        dwell_time_seconds,
        headway_trunk_seconds,
        headway_branch_seconds,
        scheduled_arrival_time as scheduled_arrival_seconds,
        scheduled_departure_time as scheduled_departure_seconds,
        scheduled_travel_time as scheduled_travel_seconds,
        scheduled_headway_trunk as scheduled_headway_trunk_seconds,
        scheduled_headway_branch as scheduled_headway_branch_seconds,
        starts_with(trip_id, 'ADDED-') as is_added_trip,
        _loaded_at
    from source

),

deduplicated as (

    select *
    from renamed
    qualify row_number() over (
            partition by service_date, trip_id, route_id, vehicle_label, stop_id
            order by stopped_at asc nulls last, moved_at asc nulls last, _loaded_at desc
        ) = 1

)

select
    {{ dbt_utils.generate_surrogate_key(['service_date', 'trip_id', 'route_id', 'vehicle_label', 'stop_id']) }}
        as trip_stop_event_key,
    *
from deduplicated
