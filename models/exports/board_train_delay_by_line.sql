{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/train_delay_by_line.parquet'
    )
}}
-- Board file for the donut: each route's share of positive train delay (mart_train_delay_by_line)
-- per service date (period_kind 'date'), over all weekdays ('weekday') and over all days
-- ('all_days'). share_of_positive_excess = route seconds / system seconds; shares in a period
-- add up to 1.

select
    delay.period_kind,
    delay.service_date,
    delay.route_id,
    routes.display_name,
    routes.route_color_hex,
    delay.service_dates,
    delay.runs_compared,
    delay.positive_excess_seconds,
    {{ format_duration('delay.positive_excess_seconds') }} as positive_excess_label,
    delay.net_excess_seconds,
    delay.avg_daily_positive_excess_seconds,
    {{ format_duration('delay.avg_daily_positive_excess_seconds') }} as avg_daily_positive_excess_label,
    delay.system_positive_excess_seconds,
    delay.share_of_positive_excess
from {{ ref('mart_train_delay_by_line') }} as delay
inner join {{ ref('dim_routes') }} as routes on delay.route_id = routes.route_id
order by delay.period_kind, delay.service_date, routes.display_order
