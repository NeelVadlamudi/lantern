-- Grain: one row per service date, trip, route, vehicle and stop (same as staging).
-- Adds Boston local event time, service period, and the schedule comparisons:
--   actual_run_seconds    = stopped_at at this stop - stopped_at at the previous observed stop
--                           (for the segment out of the first observed stop: stopped_at - moved_at)
--   scheduled_run_seconds = scheduled arrival here - scheduled departure at that previous stop
--   excess_travel_seconds = actual_run_seconds - scheduled_run_seconds
--   headway_ratio         = headway_trunk_seconds / scheduled_headway_trunk_seconds
--   is_long_gap           = headway_ratio > var('long_gap_ratio')   (default 1.5)
--   is_bunched            = headway_ratio < var('bunched_ratio')    (default 0.5)
--   is_headway_adherent   = neither long gap nor bunched
-- Why not LAMP's travel_time_seconds - scheduled_travel_time? LAMP's travel time runs from the
-- train leaving toward a stop to stopping there, so it excludes the dwell at the previous stop.
-- The GTFS schedule has arrival = departure at every subway stop, so scheduled travel includes
-- dwell. Subtracting them makes every train look about 50 seconds early per stop. Arrival-to-
-- arrival against the schedule's departure-to-arrival compares like with like, and also covers
-- spans where an intermediate stop was not observed.
-- Trunk headways are used (any train on the line), because that is the gap a rider on a shared
-- trunk platform experiences. Rows fail a comparison (flag false, metric null) when either side
-- is missing or zero or negative. Runs over var('travel_outlier_seconds') (30 minutes) are
-- compared like any other run and flagged with is_travel_outlier, so every measure includes them
-- and the marts can also show them on their own.

with trip_stops as (

    select * from {{ ref('stg_lamp__subway_trip_stops') }}

),

periods as (

    select * from {{ ref('int_service_periods') }}

),

timed as (

    select
        *,
        -- After the first observed stop (normally the origin terminal) the train's stopped_at is
        -- its arrival on the platform, often minutes before it leaves. Use moved_at (when it
        -- started toward this stop) as the departure for that one segment.
        case
            when row_number() over trip_window = 2
                then epoch(stopped_at) - epoch(moved_at)
            else epoch(stopped_at) - epoch(lag(stopped_at) over trip_window)
        end as actual_run_seconds,
        scheduled_arrival_seconds - lag(scheduled_departure_seconds) over trip_window
            as scheduled_run_seconds,
        {{ to_boston_time('coalesce(stopped_at, moved_at)') }} as event_local_at,
        -- seconds since midnight at the start of the service date; trips after midnight exceed 86400
        epoch({{ to_boston_time('coalesce(stopped_at, moved_at)') }})
        - epoch(cast(service_date as timestamp)) as event_service_seconds
    from trip_stops
    window trip_window as (
        partition by service_date, trip_id, route_id, vehicle_label
        order by stop_sequence, stopped_at
    )

),

compared as (

    select
        timed.*,
        timed.actual_run_seconds > {{ var('travel_outlier_seconds') }} as is_travel_outlier,
        coalesce(
            timed.actual_run_seconds > 0
            and timed.scheduled_run_seconds > 0,
            false
        ) as has_travel_comparison,
        coalesce(timed.headway_trunk_seconds > 0 and timed.scheduled_headway_trunk_seconds > 0, false)
            as has_headway_comparison
    from timed

)

select
    compared.trip_stop_event_key,
    compared.service_date,
    compared.trip_id,
    compared.route_id,
    compared.branch_route_id,
    compared.line_id,
    compared.direction_id,
    compared.direction,
    compared.direction_destination,
    compared.vehicle_label,
    compared.stop_id,
    compared.station_id,
    compared.stop_sequence,
    compared.is_added_trip,
    compared.event_local_at,
    compared.event_service_seconds,
    periods.service_period_id,
    compared.travel_time_seconds,
    compared.scheduled_travel_seconds,
    compared.actual_run_seconds,
    compared.scheduled_run_seconds,
    compared.dwell_time_seconds,
    compared.headway_trunk_seconds,
    compared.scheduled_headway_trunk_seconds,
    compared.headway_branch_seconds,
    compared.scheduled_headway_branch_seconds,
    compared.is_travel_outlier,
    compared.has_travel_comparison,
    compared.has_headway_comparison,
    case
        when compared.has_travel_comparison
            then compared.actual_run_seconds - compared.scheduled_run_seconds
    end as excess_travel_seconds,
    case
        when compared.has_headway_comparison
            then {{ safe_ratio('compared.headway_trunk_seconds', 'compared.scheduled_headway_trunk_seconds') }}
    end as headway_ratio,
    coalesce(
        compared.has_headway_comparison
        and compared.headway_trunk_seconds
        > {{ var('long_gap_ratio') }} * compared.scheduled_headway_trunk_seconds,
        false
    ) as is_long_gap,
    coalesce(
        compared.has_headway_comparison
        and compared.headway_trunk_seconds
        < {{ var('bunched_ratio') }} * compared.scheduled_headway_trunk_seconds,
        false
    ) as is_bunched,
    compared._loaded_at
from compared
left join periods
    on cast(floor(compared.event_service_seconds / 60) as integer) % 1440 = periods.minute_of_day
