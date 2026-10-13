-- Grain: one row per scope and service date: every GTFS route ('route'), every line
-- ('line': Green = the four branches, which the station views use), 'Green' as a route-level
-- scope for the combined branches, and 'system'. A scope-day has a planned change when any of
-- its routes has one (mart_planned_change_line_days); planned_change_lines counts the routes.
-- Used to keep planned-change days out of typical values (see typical_window_excluding()).

with route_days as (

    select
        planned.route_id,
        routes.line_id,
        planned.service_date,
        planned.is_planned_change
    from {{ ref('mart_planned_change_line_days') }} as planned
    inner join {{ ref('dim_routes') }} as routes on planned.route_id = routes.route_id

),

scoped as (

    select
        'route' as scope_type,
        route_id as scope_id,
        service_date,
        is_planned_change,
        route_id
    from route_days
    union all
    select
        'line' as scope_type,
        line_id as scope_id,
        service_date,
        is_planned_change,
        route_id
    from route_days
    union all
    select
        'route' as scope_type,
        'Green' as scope_id,
        service_date,
        is_planned_change,
        route_id
    from route_days
    where route_id like 'Green-%'
    union all
    select
        'route' as scope_type,
        'system' as scope_id,
        service_date,
        is_planned_change,
        route_id
    from route_days
    union all
    select
        'line' as scope_type,
        'system' as scope_id,
        service_date,
        is_planned_change,
        route_id
    from route_days

)

select
    {{ dbt_utils.generate_surrogate_key(['scope_type', 'scope_id', 'service_date']) }} as scope_day_key,
    cast(scope_type as varchar) as scope_type,
    cast(scope_id as varchar) as scope_id,
    cast(service_date as date) as service_date,
    cast(bool_or(is_planned_change) as boolean) as is_planned_change,
    cast(count(*) filter (where is_planned_change) as bigint) as planned_change_lines,
    cast(
        case
            when bool_or(is_planned_change)
                then 'Planned service change on '
                    || string_agg(route_id, ', ' order by route_id) filter (where is_planned_change)
        end as varchar
    ) as planned_change_label
from scoped
group by scope_type, scope_id, service_date
