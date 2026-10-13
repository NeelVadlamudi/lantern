-- Grain: one row per service date, line (GTFS route) and service change record.
-- Two public sources, both read in dbt:
--   alerts        LAMP_RT_ALERTS (archived GTFS-realtime service alerts, stg_lamp__rt_alerts).
--                 The latest version of each alert that lists active periods gives its
--                 periods, text and stops (the version that closes an alert lists none).
--                 Kept: shuttles, suspensions, station closures, service and schedule changes,
--                 and delays that were announced in advance (planned work such as single
--                 tracking). Unplanned delays (police activity, disabled train) are not service
--                 changes and are left out.
--   gtfs_schedule GTFS archive: a line-day whose published timetable runs under a planned
--                 diversion service (service_id starting 'DIV', int_scheduled_subway_trips).
-- is_planned: alerts created at least var('planned_notice_hours') (24) hours before their first
--   active period starts; every GTFS diversion timetable is planned.
-- change_type: shuttle (effect detail SHUTTLE), closure (SUSPENSION or STATION_CLOSURE),
--   slow_zone (header names a speed restriction or slow zone), diversion (any other planned
--   change, including GTFS diversion timetables and announced single tracking).
-- affects_line_day: true for every GTFS diversion timetable, and for alerts with effect
--   detail SHUTTLE or SUSPENSION that name at least two stations of this route. Station
--   closures, single tracking and other announced work without a diversion timetable, service
--   or schedule change notices and slow zones are listed but do not mark the line-day
--   (mart_planned_change_line_days).
-- Service date: an active period counts on every service date (3 AM to 3 AM) it overlaps. An
--   open-ended period ends when the alert's last version closed it, or runs to the last loaded
--   date while the alert is still open.
-- from/to stations: of the alert's informed stops on this line, the first and last in the
--   line's direction-0 stop order (int_line_stop_sequence); null when the alert names no stops
--   (whole line) and for GTFS records.

with dates as (

    select date_day as service_date from {{ ref('dim_dates') }}

),

window_end as (

    select max(service_date) as last_date from dates

),

routes as (

    select route_id from {{ ref('dim_routes') }}

),

alerts as (

    select alerts.*
    from {{ ref('stg_lamp__rt_alerts') }} as alerts
    inner join routes on alerts.route_id = routes.route_id

),

latest_version as (

    -- the last version that still lists active periods (the closing version lists none)
    select
        alert_id,
        max(alert_version_timestamp) filter (where active_start_at is not null) as alert_version_timestamp,
        min(created_at) as first_created_at,
        -- when the alert's last published version closed it (null while it is still open)
        arg_max(closed_at, alert_version_timestamp) as closed_at
    from alerts
    group by alert_id
    having count(active_start_at) > 0

),

latest as (

    select
        alerts.* exclude (closed_at),  -- noqa: RF02
        latest_version.first_created_at,
        latest_version.closed_at
    from alerts
    inner join latest_version
        on
            alerts.alert_id = latest_version.alert_id
            and alerts.alert_version_timestamp = latest_version.alert_version_timestamp

),

alert_info as (

    select
        alert_id,
        any_value(first_created_at) as first_created_at,
        min(active_start_at) as first_active_start_at,
        arg_max(effect, active_start_at) as effect,
        arg_max(effect_detail, active_start_at) as effect_detail,
        arg_max(cause, active_start_at) as cause,
        arg_max(header_text, active_start_at) as header_text,
        any_value(closed_at) as closed_at
    from latest
    group by alert_id

),

classified as (

    select
        alert_info.*,
        alert_info.first_created_at
        <= alert_info.first_active_start_at - interval '{{ var("planned_notice_hours") }} hours' as is_planned,
        case
            when
                alert_info.header_text ilike '%speed restriction%'
                or alert_info.header_text ilike '%slow zone%'
                then 'slow_zone'
            when alert_info.effect_detail = 'SHUTTLE' then 'shuttle'
            when alert_info.effect_detail in ('SUSPENSION', 'STATION_CLOSURE') then 'closure'
            else 'diversion'
        end as change_type
    from alert_info

),

kept as (

    select *
    from classified
    where
        effect_detail in ('SHUTTLE', 'SUSPENSION', 'STATION_CLOSURE', 'SERVICE_CHANGE', 'SCHEDULE_CHANGE')
        or change_type = 'slow_zone'
        or (effect_detail = 'DELAY' and is_planned)

),

periods as (

    select distinct
        latest.alert_id,
        latest.route_id,
        latest.active_start_at,
        coalesce(latest.active_end_at, kept.closed_at) as active_end_at
    from latest
    inner join kept on latest.alert_id = kept.alert_id

),

alert_days as (

    select distinct
        periods.alert_id,
        periods.route_id,
        dates.service_date
    from periods
    cross join window_end
    inner join dates
        on
            dates.service_date >= cast(periods.active_start_at - interval '3 hours' as date)
            and dates.service_date <= coalesce(
                cast(periods.active_end_at - interval '3 hours' - interval '1 second' as date),
                window_end.last_date
            )

),

stops as (

    select
        stop_id,
        arg_max(parent_station_id, valid_from_date) as parent_station_id
    from {{ ref('stg_gtfs__stops') }}
    group by stop_id

),

stop_order as (

    select
        route_id,
        station_id,
        min(stop_order) as stop_order
    from {{ ref('int_line_stop_sequence') }}
    where direction_id = 0
    group by route_id, station_id

),

alert_stations as (

    select distinct
        latest.alert_id,
        latest.route_id,
        case
            when latest.stop_id like 'place-%' then latest.stop_id
            else stops.parent_station_id
        end as station_id
    from latest
    inner join kept on latest.alert_id = kept.alert_id
    left join stops on latest.stop_id = stops.stop_id
    where latest.stop_id is not null

),

alert_ends as (

    select
        alert_stations.alert_id,
        alert_stations.route_id,
        arg_min(alert_stations.station_id, stop_order.stop_order) as from_station_id,
        arg_max(alert_stations.station_id, stop_order.stop_order) as to_station_id,
        count(distinct alert_stations.station_id) as stations_named
    from alert_stations
    inner join stop_order
        on
            alert_stations.route_id = stop_order.route_id
            and alert_stations.station_id = stop_order.station_id
    group by alert_stations.alert_id, alert_stations.route_id

),

from_alerts as (

    select
        alert_days.service_date,
        alert_days.route_id,
        'alerts' as source,  -- noqa: RF04
        kept.change_type,
        kept.is_planned,
        -- the line's own service changed: shuttle buses or a suspension on this route
        -- covering at least two of its stations (a stretch of line, not one stop)
        kept.effect_detail in ('SHUTTLE', 'SUSPENSION')
        and coalesce(alert_ends.stations_named, 0) >= 2 as affects_line_day,
        alert_ends.from_station_id,
        alert_ends.to_station_id,
        alert_ends.stations_named,
        kept.alert_id,
        kept.effect,
        kept.effect_detail,
        kept.cause,
        kept.header_text,
        kept.first_created_at as alert_created_at,
        kept.first_active_start_at as alert_first_active_at,
        cast(null as varchar) as service_id
    from alert_days
    inner join kept on alert_days.alert_id = kept.alert_id
    left join alert_ends
        on
            alert_days.alert_id = alert_ends.alert_id
            and alert_days.route_id = alert_ends.route_id

),

from_gtfs as (

    select distinct
        scheduled.service_date,
        scheduled.route_id,
        'gtfs_schedule' as source,  -- noqa: RF04
        'diversion' as change_type,
        true as is_planned,
        true as affects_line_day,
        cast(null as varchar) as from_station_id,
        cast(null as varchar) as to_station_id,
        cast(null as bigint) as stations_named,
        cast(null as bigint) as alert_id,
        cast(null as varchar) as effect,
        cast(null as varchar) as effect_detail,
        cast(null as varchar) as cause,
        cast(null as varchar) as header_text,
        cast(null as timestamp) as alert_created_at,
        cast(null as timestamp) as alert_first_active_at,
        scheduled.service_id
    from {{ ref('int_scheduled_subway_trips') }} as scheduled
    where scheduled.service_id like 'DIV%'

),

unioned as (

    select * from from_alerts
    union all
    select * from from_gtfs

)

select
    {{ dbt_utils.generate_surrogate_key([
        'unioned.service_date', 'unioned.route_id', 'unioned.source', 'unioned.alert_id', 'unioned.service_id'
    ]) }} as service_change_key,
    cast(unioned.service_date as date) as service_date,
    cast(strftime(unioned.service_date, '%Y%m%d') as integer) as date_key,
    cast(unioned.route_id as varchar) as route_id,
    cast(routes.line_id as varchar) as line_id,
    cast(unioned.source as varchar) as source,  -- noqa: RF04
    cast(unioned.change_type as varchar) as change_type,
    cast(unioned.is_planned as boolean) as is_planned,
    cast(unioned.affects_line_day as boolean) as affects_line_day,
    cast(unioned.from_station_id as varchar) as from_station_id,
    cast(from_station.station_name as varchar) as from_station_name,
    cast(unioned.to_station_id as varchar) as to_station_id,
    cast(to_station.station_name as varchar) as to_station_name,
    cast(unioned.stations_named as bigint) as stations_named,
    cast(unioned.alert_id as bigint) as alert_id,
    cast(unioned.effect as varchar) as effect,
    cast(unioned.effect_detail as varchar) as effect_detail,
    cast(unioned.cause as varchar) as cause,
    cast(unioned.header_text as varchar) as header_text,
    cast(unioned.alert_created_at as timestamp) as alert_created_at,
    cast(unioned.alert_first_active_at as timestamp) as alert_first_active_at,
    cast(unioned.service_id as varchar) as service_id
from unioned
inner join {{ ref('dim_routes') }} as routes on unioned.route_id = routes.route_id
left join {{ ref('dim_stations') }} as from_station on unioned.from_station_id = from_station.station_id
left join {{ ref('dim_stations') }} as to_station on unioned.to_station_id = to_station.station_id
