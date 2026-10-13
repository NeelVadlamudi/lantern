{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/service_changes.parquet'
    )
}}
-- Board file: service changes per line and service date (mart_service_changes), from the MBTA
-- service alerts archive (LAMP_RT_ALERTS) and GTFS diversion timetables, with display names.
-- is_planned and affects_line_day decide whether the line-day is a planned change.
-- alert_header (with display_alert_id and display_effect_detail) is the alert text to show: its
-- own text on an alert row, the same-day planned alert on the route for a diversion timetable.

select
    changes.service_date,
    changes.route_id,
    routes.display_name,
    changes.line_id,
    changes.change_type,
    changes.source,
    changes.is_planned,
    changes.affects_line_day,
    changes.from_station_id,
    changes.from_station_name,
    changes.to_station_id,
    changes.to_station_name,
    changes.alert_id,
    changes.effect_detail,
    changes.cause,
    changes.header_text,
    changes.alert_created_at,
    changes.service_id,
    changes.display_alert_id,
    changes.display_effect_detail,
    changes.alert_header
from {{ ref('mart_service_changes') }} as changes
inner join {{ ref('dim_routes') }} as routes on changes.route_id = routes.route_id
order by changes.service_date, routes.display_order, changes.source, changes.alert_id
