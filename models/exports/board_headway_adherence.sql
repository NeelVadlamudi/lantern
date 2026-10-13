{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/headway_adherence.parquet'
    )
}}
-- Board file: bunched and gapped departures (SFMTA rules) per line scope, service date and
-- service hour (mart_headway_adherence), with the scope's display name and the planned-change
-- flag and label of that scope and day (mart_planned_change_scope_days).

select
    adherence.scope_id,
    coalesce(routes.display_name, 'All subway lines') as scope_name,
    adherence.service_date,
    adherence.day_type,
    coalesce(planned.is_planned_change, false) as is_planned_change,
    planned.planned_change_label,
    adherence.service_hour,
    adherence.departures_compared,
    adherence.bunched_departures,
    adherence.gapped_departures,
    adherence.bunched_share,
    adherence.gapped_share
from {{ ref('mart_headway_adherence') }} as adherence
left join {{ ref('dim_routes') }} as routes on adherence.scope_id = routes.route_id
left join {{ ref('mart_planned_change_scope_days') }} as planned
    on
        planned.scope_type = 'route'
        and adherence.scope_id = planned.scope_id
        and adherence.service_date = planned.service_date
order by adherence.service_date, coalesce(routes.display_order, 0), adherence.service_hour
