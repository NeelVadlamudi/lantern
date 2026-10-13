{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_day_completeness.parquet'
    )
}}
-- Board file: trips compared against trips scheduled per line scope and service date
-- (mart_line_day_completeness), with the low-completeness flag and its threshold. Completeness
-- is matched trips compared / scheduled trips (at most 1); unmatched and added runs are separate.

select
    completeness.scope_id,
    coalesce(routes.display_name, 'All subway lines') as scope_name,
    completeness.service_date,
    completeness.day_type,
    completeness.scheduled_trips,
    completeness.trips_observed,
    completeness.trips_compared,
    completeness.matched_trips_compared,
    completeness.matched_runs_compared,
    completeness.unmatched_runs_compared,
    completeness.added_runs_compared,
    completeness.duplicate_stop_events_dropped,
    completeness.completeness_share,
    completeness.completeness_min_share,
    completeness.is_low_completeness,
    completeness.is_planned_change,
    completeness.planned_change_lines,
    completeness.planned_change_label
from {{ ref('mart_line_day_completeness') }} as completeness
left join {{ ref('dim_routes') }} as routes on completeness.scope_id = routes.route_id
order by completeness.service_date, coalesce(routes.display_order, 0)
