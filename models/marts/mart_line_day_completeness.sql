-- Grain: one row per line scope ('system' or a subway route id) and service date in the window.
-- How much of the published schedule the day's figures rest on:
--   scheduled_trips         trips in the GTFS schedule for that date (int_scheduled_subway_trips)
--   trips_observed          train runs LAMP recorded after duplicate stop events are removed
--                           (fct_trips: one per trip id and vehicle)
--   matched_trips_compared  scheduled trips with at least one compared run under their own trip
--                           id. Counted from the schedule side, so it can never exceed
--                           scheduled_trips. trips_compared repeats it (completeness numerator).
--   matched_runs_compared   compared train runs whose trip id is scheduled that date: the
--                           denominator of the late share. A trip run by two vehicles is two runs.
--   unmatched_runs_compared compared runs whose trip id is not in the day's schedule; of them,
--   added_runs_compared     the runs LAMP marks as added ('ADDED-' ids). Not in the late share.
--   duplicate_stop_events_dropped  stop events dropped as the same train recorded twice
--   completeness_share = matched_trips_compared / scheduled_trips (at most 1)
--   is_low_completeness = completeness_share < var('completeness_min_share') (0.8).
--   is_planned_change (mart_planned_change_line_days): for a line, the line-day had a planned
--     service change; for 'system', at least one line did (planned_change_lines). On those days
--     a low share usually reflects the diversion timetable, not missing data.

with scheduled_trips as (

    select * from {{ ref('int_scheduled_subway_trips') }}

),

trips as (

    select * from {{ ref('fct_trips') }}

),

compared_scheduled as (

    select distinct
        scheduled_trips.route_id,
        scheduled_trips.service_date,
        scheduled_trips.trip_id
    from scheduled_trips
    inner join trips
        on
            scheduled_trips.service_date = trips.service_date
            and scheduled_trips.trip_id = trips.trip_id
    where trips.compared_segments > 0

),

scheduled_by_route as (

    select
        scheduled_trips.route_id,
        scheduled_trips.service_date,
        count(*) as scheduled_trips,
        count(compared_scheduled.trip_id) as matched_trips_compared
    from scheduled_trips
    left join compared_scheduled
        on
            scheduled_trips.route_id = compared_scheduled.route_id
            and scheduled_trips.service_date = compared_scheduled.service_date
            and scheduled_trips.trip_id = compared_scheduled.trip_id
    group by scheduled_trips.route_id, scheduled_trips.service_date

),

scheduled as (

    select
        route_id as scope_id,
        service_date,
        scheduled_trips,
        matched_trips_compared
    from scheduled_by_route

    union all

    select
        'system' as scope_id,
        service_date,
        sum(scheduled_trips) as scheduled_trips,
        sum(matched_trips_compared) as matched_trips_compared
    from scheduled_by_route
    group by service_date

),

observed_by_route as (

    select
        route_id,
        service_date,
        count(*) as trips_observed,
        count(*) filter (where compared_segments > 0 and is_matched_trip) as matched_runs_compared,
        count(*) filter (where compared_segments > 0 and not is_matched_trip) as unmatched_runs_compared,
        count(*) filter (where compared_segments > 0 and not is_matched_trip and is_added_trip)
            as added_runs_compared,
        sum(duplicate_events_dropped) as duplicate_stop_events_dropped
    from trips
    group by route_id, service_date

),

observed as (

    select
        route_id as scope_id,
        service_date,
        trips_observed,
        matched_runs_compared,
        unmatched_runs_compared,
        added_runs_compared,
        duplicate_stop_events_dropped
    from observed_by_route

    union all

    select
        'system' as scope_id,
        service_date,
        sum(trips_observed) as trips_observed,
        sum(matched_runs_compared) as matched_runs_compared,
        sum(unmatched_runs_compared) as unmatched_runs_compared,
        sum(added_runs_compared) as added_runs_compared,
        sum(duplicate_stop_events_dropped) as duplicate_stop_events_dropped
    from observed_by_route
    group by service_date

),

planned as (

    select
        route_id as scope_id,
        service_date,
        is_planned_change,
        cast(is_planned_change as integer) as planned_change_lines,
        planned_change_label
    from {{ ref('mart_planned_change_line_days') }}

    union all

    select
        'system' as scope_id,
        service_date,
        bool_or(is_planned_change) as is_planned_change,
        count(*) filter (where is_planned_change) as planned_change_lines,
        case
            when bool_or(is_planned_change)
                then 'Planned service change on '
                    || string_agg(route_id, ', ' order by route_id) filter (where is_planned_change)
        end as planned_change_label
    from {{ ref('mart_planned_change_line_days') }}
    group by service_date

),

scopes as (

    select distinct scope_id from scheduled
    union
    select distinct scope_id from observed

),

grid as (

    select
        scopes.scope_id,
        dates.date_day as service_date,
        dates.date_key,
        dates.day_type
    from scopes
    cross join {{ ref('dim_dates') }} as dates

)

select
    cast(grid.scope_id as varchar) as scope_id,
    cast(grid.service_date as date) as service_date,
    cast(grid.date_key as integer) as date_key,
    cast(grid.day_type as varchar) as day_type,
    cast(coalesce(scheduled.scheduled_trips, 0) as bigint) as scheduled_trips,
    cast(coalesce(observed.trips_observed, 0) as bigint) as trips_observed,
    cast(coalesce(scheduled.matched_trips_compared, 0) as bigint) as trips_compared,
    cast(coalesce(scheduled.matched_trips_compared, 0) as bigint) as matched_trips_compared,
    cast(coalesce(observed.matched_runs_compared, 0) as bigint) as matched_runs_compared,
    cast(coalesce(observed.unmatched_runs_compared, 0) as bigint) as unmatched_runs_compared,
    cast(coalesce(observed.added_runs_compared, 0) as bigint) as added_runs_compared,
    cast(coalesce(observed.duplicate_stop_events_dropped, 0) as bigint) as duplicate_stop_events_dropped,
    cast(scheduled.matched_trips_compared / nullif(scheduled.scheduled_trips, 0) as double) as completeness_share,
    cast({{ var('completeness_min_share') }} as double) as completeness_min_share,
    cast(
        coalesce(scheduled.matched_trips_compared, 0)
        < {{ var('completeness_min_share') }} * coalesce(scheduled.scheduled_trips, 0)
        as boolean
    ) as is_low_completeness,
    cast(coalesce(planned.is_planned_change, false) as boolean) as is_planned_change,
    cast(coalesce(planned.planned_change_lines, 0) as bigint) as planned_change_lines,
    cast(planned.planned_change_label as varchar) as planned_change_label
from grid
left join scheduled on grid.scope_id = scheduled.scope_id and grid.service_date = scheduled.service_date
left join observed on grid.scope_id = observed.scope_id and grid.service_date = observed.service_date
left join planned on grid.scope_id = planned.scope_id and grid.service_date = planned.service_date
