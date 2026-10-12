{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_day_metrics.parquet'
    )
}}
-- Board file for the date filter: every day's measures per line and for the whole subway, each
-- with the typical value for the same day type over the earlier var('typical_days') days of that
-- day type (mart_line_day_metrics). Long format: one row per scope, service date and measure.
-- scope_id is 'system' (all subway routes), a route id, or 'Green' (the four Green Line branches
-- combined). Shares are numerator / denominator;
-- *_label is format_duration of the seconds measures (null for counts and shares).

select
    metrics.scope_id,
    case
        when metrics.scope_id = 'Green' then 'Green Line (all branches)'
        else coalesce(routes.display_name, 'All subway lines')
    end as scope_name,
    coalesce(routes.route_color_hex, green.route_color_hex) as route_color_hex,
    metrics.service_date,
    metrics.day_type,
    metrics.measure,
    metrics.unit,
    metrics.value,
    metrics.numerator,
    metrics.denominator,
    metrics.typical_days,
    metrics.typical_first_date,
    metrics.typical_last_date,
    metrics.typical_median,
    metrics.typical_mean,
    metrics.typical_p25,
    metrics.typical_p75,
    metrics.diff_vs_median,
    metrics.diff_vs_mean,
    case when metrics.unit = 'seconds' then {{ format_duration('metrics.value') }} end as value_label,
    case when metrics.unit = 'seconds' then {{ format_duration('metrics.typical_median') }} end
        as typical_median_label,
    case when metrics.unit = 'seconds' then {{ format_duration('metrics.diff_vs_median') }} end
        as diff_vs_median_label
from {{ ref('mart_line_day_metrics') }} as metrics
left join {{ ref('dim_routes') }} as routes on metrics.scope_id = routes.route_id
left join {{ ref('dim_routes') }} as green on metrics.scope_id = 'Green' and green.route_id = 'Green-B'
order by metrics.service_date, coalesce(routes.display_order, 0), metrics.measure
