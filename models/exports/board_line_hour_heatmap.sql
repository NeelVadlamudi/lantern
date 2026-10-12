{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_hour_heatmap.parquet'
    )
}}
-- Board file for the hour x date heatmap per line (mart_line_hour_heatmap). Grain: one row per
-- scope ('system' or a route id), service date and service hour (Boston time, hours after
-- midnight of the service date, so 24 to 27 are after midnight). Every rate carries its
-- numerator and denominator; the usual_* flags compare the hour with the same hour on the
-- earlier var('typical_days') days of the same day type (see meta.thresholds).

select
    heatmap.*,
    coalesce(routes.display_name, 'All subway lines') as scope_name
from {{ ref('mart_line_hour_heatmap') }} as heatmap
left join {{ ref('dim_routes') }} as routes on heatmap.scope_id = routes.route_id
order by heatmap.scope_id, heatmap.service_date, heatmap.service_hour
