{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_day_completeness.parquet'
    )
}}
-- Board file: trips compared against trips scheduled per line scope and service date
-- (mart_line_day_completeness), with the low-completeness flag and its threshold.

select
    completeness.scope_id,
    coalesce(routes.display_name, 'All subway lines') as scope_name,
    completeness.service_date,
    completeness.day_type,
    completeness.scheduled_trips,
    completeness.trips_observed,
    completeness.trips_compared,
    completeness.completeness_share,
    completeness.completeness_min_share,
    completeness.is_low_completeness
from {{ ref('mart_line_day_completeness') }} as completeness
left join {{ ref('dim_routes') }} as routes on completeness.scope_id = routes.route_id
order by completeness.service_date, coalesce(routes.display_order, 0)
