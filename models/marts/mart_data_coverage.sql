-- Grain: one row per GTFS route, over the loaded window.
-- How much of the data can be compared to the schedule, and how much of it has rider weights.
-- "No scheduled travel time" = LAMP gives no scheduled run time to this stop, or zero or less
-- (first stop of a trip, added trips, source gaps). "No scheduled headway" = no scheduled trunk
-- gap, or zero. Stations without gated entries do not appear in MBTA's gated-entry data: Green
-- Line surface stops, Symphony, Mattapan trolley stops other than Ashmont and Mattapan, and
-- Longwood (its gated rows have no stop id; see the warn test on stg_mbta__gated_entries).

with events as (

    select
        route_id,
        line_id,
        station_id,
        coalesce(scheduled_run_seconds, 0) <= 0 as no_scheduled_travel,
        coalesce(scheduled_headway_seconds, 0) <= 0 as no_scheduled_headway
    from {{ ref('fct_trip_stop_events') }}

),

stations as (

    select
        station_id,
        has_gated_entries
    from {{ ref('mart_station_overview') }}

),

joined as (

    select
        events.*,
        coalesce(stations.has_gated_entries, false) as has_gated_entries
    from events
    left join stations
        on events.station_id = stations.station_id

)

select
    cast(route_id as varchar) as route_id,
    cast(max(line_id) as varchar) as line_id,
    cast(count(*) as bigint) as trip_stop_events,
    cast(count(*) filter (where no_scheduled_travel) as bigint) as events_without_scheduled_travel,
    cast(count(*) filter (where no_scheduled_headway) as bigint) as events_without_scheduled_headway,
    cast(count(*) filter (where no_scheduled_travel and no_scheduled_headway) as bigint)
        as events_without_any_schedule,
    cast(avg(cast(no_scheduled_travel as int)) as double) as share_without_scheduled_travel,
    cast(avg(cast(no_scheduled_headway as int)) as double) as share_without_scheduled_headway,
    cast(avg(cast(no_scheduled_travel and no_scheduled_headway as int)) as double)
        as share_without_any_schedule,
    cast(count(distinct station_id) as bigint) as stations_served,
    cast(count(distinct station_id) filter (where not has_gated_entries) as bigint)
        as stations_without_gated_entries,
    cast(count(*) filter (where not has_gated_entries) as bigint) as events_at_ungated_stations,
    cast(avg(cast(not has_gated_entries as int)) as double) as share_events_at_ungated_stations
from joined
group by route_id
