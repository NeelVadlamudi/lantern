-- Grain: one row per line scope ('system' or a subway route id) and service date in the window.
-- How much of the published schedule the day's figures rest on:
--   scheduled_trips  trips in the GTFS schedule for that date (int_scheduled_subway_trips)
--   trips_observed   train runs LAMP recorded (fct_trips: one per trip and vehicle, so a trip
--                    run by two vehicles or an added trip can push this above scheduled)
--   trips_compared   runs with at least one stop-to-stop comparison (the late-trip denominator)
--   completeness_share = trips_compared / scheduled_trips
--   is_low_completeness = completeness_share < var('completeness_min_share') (0.8: at least one
--     in five scheduled trips has no compared run). A low day can be missing LAMP data or real
--     service changes (shuttles, diversions); the flag says the day's figures cover less of the
--     schedule, not which of the two it was.

with scheduled as (

    select
        route_id as scope_id,
        service_date,
        count(*) as scheduled_trips
    from {{ ref('int_scheduled_subway_trips') }}
    group by route_id, service_date

    union all

    select
        'system' as scope_id,
        service_date,
        count(*) as scheduled_trips
    from {{ ref('int_scheduled_subway_trips') }}
    group by service_date

),

observed as (

    select
        route_id as scope_id,
        service_date,
        count(*) as trips_observed,
        count(*) filter (where compared_segments > 0) as trips_compared
    from {{ ref('fct_trips') }}
    group by route_id, service_date

    union all

    select
        'system' as scope_id,
        service_date,
        count(*) as trips_observed,
        count(*) filter (where compared_segments > 0) as trips_compared
    from {{ ref('fct_trips') }}
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
    cast(coalesce(observed.trips_compared, 0) as bigint) as trips_compared,
    cast(observed.trips_compared / nullif(scheduled.scheduled_trips, 0) as double) as completeness_share,
    cast({{ var('completeness_min_share') }} as double) as completeness_min_share,
    cast(
        coalesce(observed.trips_compared, 0)
        < {{ var('completeness_min_share') }} * coalesce(scheduled.scheduled_trips, 0)
        as boolean
    ) as is_low_completeness
from grid
left join scheduled on grid.scope_id = scheduled.scope_id and grid.service_date = scheduled.service_date
left join observed on grid.scope_id = observed.scope_id and grid.service_date = observed.service_date
