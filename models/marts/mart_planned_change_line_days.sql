-- Grain: one row per line (GTFS route) and service date in the loaded window.
-- is_planned_change: the line-day has at least one planned service change that affects the
-- line's own service (mart_service_changes: is_planned and affects_line_day): a diversion
-- timetable, or a planned shuttle or suspension over at least two stations of the line.
-- Other planned records (station closures, single tracking without a diversion timetable,
-- notices, slow zones) are counted in station_closures but do not set the flag.
-- These line-days are left out of the headline tiles, the line totals and the typical ranges,
-- and stay in the day views with planned_change_label. The MBTA leaves planned diversion days
-- out of its Service Delivery Policy reliability results (Fall 2024 SDP report).

with grid as (

    select
        routes.route_id,
        dates.date_day as service_date,
        dates.day_type
    from {{ ref('dim_routes') }} as routes
    cross join {{ ref('dim_dates') }} as dates

),

changes as (

    select * from {{ ref('mart_service_changes') }}

),

planned as (

    select
        route_id,
        service_date,
        string_agg(distinct change_type, ', ' order by change_type) as planned_change_types,
        string_agg(distinct cast(alert_id as varchar), ', ' order by cast(alert_id as varchar))
            as planned_alert_ids,
        bool_or(source = 'gtfs_schedule') as has_diversion_timetable,
        bool_or(source = 'alerts') as has_planned_alert,
        count(*) as planned_change_records
    from changes
    where is_planned and affects_line_day
    group by route_id, service_date

),

station_closures as (

    select
        route_id,
        service_date,
        count(distinct alert_id) as station_closures
    from changes
    where is_planned and not affects_line_day
    group by route_id, service_date

)

select
    {{ dbt_utils.generate_surrogate_key(['grid.route_id', 'grid.service_date']) }} as line_day_key,
    cast(grid.route_id as varchar) as route_id,
    cast(grid.service_date as date) as service_date,
    cast(grid.day_type as varchar) as day_type,
    cast(planned.route_id is not null as boolean) as is_planned_change,
    cast(planned.planned_change_types as varchar) as planned_change_types,
    cast(planned.planned_alert_ids as varchar) as planned_alert_ids,
    cast(coalesce(planned.has_diversion_timetable, false) as boolean) as has_diversion_timetable,
    cast(coalesce(planned.has_planned_alert, false) as boolean) as has_planned_alert,
    cast(coalesce(planned.planned_change_records, 0) as bigint) as planned_change_records,
    cast(coalesce(station_closures.station_closures, 0) as bigint) as station_closures,
    cast(
        case
            when planned.route_id is null then null
            else 'Planned service change: ' || planned.planned_change_types
                || case
                    when planned.has_diversion_timetable then ' (diversion timetable)'
                    else ''
                end
        end as varchar
    ) as planned_change_label
from grid
left join planned
    on grid.route_id = planned.route_id and grid.service_date = planned.service_date
left join station_closures
    on grid.route_id = station_closures.route_id and grid.service_date = station_closures.service_date
