{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/station_trend.parquet'
    )
}}
-- Board file: "getting worse" per station and line (mart_station_trend). Grain: one row per
-- station and line. Exact seconds plus labels.

select
    trend.station_id,
    trend.station_name,
    trend.line_id,
    stations.latitude,
    stations.longitude,
    trend.prior_start_date,
    trend.prior_end_date,
    trend.recent_start_date,
    trend.recent_end_date,
    trend.departures_recent,
    trend.departures_prior,
    trend.excess_seconds_per_rider_recent as excess_per_rider_recent_seconds,
    {{ format_duration('trend.excess_seconds_per_rider_recent') }} as excess_per_rider_recent_label,
    trend.excess_seconds_per_rider_prior as excess_per_rider_prior_seconds,
    {{ format_duration('trend.excess_seconds_per_rider_prior') }} as excess_per_rider_prior_label,
    trend.delta_excess_seconds,
    {{ format_duration('trend.delta_excess_seconds') }} as delta_excess_label,
    trend.typical_delta_excess_seconds,
    {{ format_duration('trend.typical_delta_excess_seconds') }} as typical_delta_excess_label,
    trend.avg_daily_rider_seconds_lost_recent as avg_daily_rider_time_lost_recent_seconds,
    {{ format_duration('trend.avg_daily_rider_seconds_lost_recent') }} as avg_daily_rider_time_lost_recent_label,
    trend.avg_daily_rider_seconds_lost_prior as avg_daily_rider_time_lost_prior_seconds,
    {{ format_duration('trend.avg_daily_rider_seconds_lost_prior') }} as avg_daily_rider_time_lost_prior_label,
    trend.loss_share_recent,
    trend.loss_share_prior,
    trend.loss_share_change,
    trend.meets_volume_threshold,
    trend.is_getting_worse
from {{ ref('mart_station_trend') }} as trend
left join {{ ref('dim_stations') }} as stations on trend.station_id = stations.station_id
order by trend.station_id, trend.line_id
