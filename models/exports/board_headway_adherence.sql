{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/headway_adherence.parquet'
    )
}}
-- Board file: bunched and gapped departures (SFMTA rules) per line scope, service date and
-- service hour (mart_headway_adherence), with the scope's display name.

select
    adherence.scope_id,
    coalesce(routes.display_name, 'All subway lines') as scope_name,
    adherence.service_date,
    adherence.day_type,
    adherence.service_hour,
    adherence.departures_compared,
    adherence.bunched_departures,
    adherence.gapped_departures,
    adherence.bunched_share,
    adherence.gapped_share
from {{ ref('mart_headway_adherence') }} as adherence
left join {{ ref('dim_routes') }} as routes on adherence.scope_id = routes.route_id
order by adherence.service_date, coalesce(routes.display_order, 0), adherence.service_hour
