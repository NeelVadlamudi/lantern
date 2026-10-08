{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/segments.parquet'
    )
}}
-- Board file: track segments with geometry, reliability, buffer time, rider-weighted loss,
-- schedule-or-service class and the "getting worse" comparison (dim_segments,
-- mart_segment_reliability, mart_segment_trend). Grain: one row per segment.
-- Every time measure is exact seconds (<metric>_seconds) plus a label from format_duration
-- (<metric>_label). Rider-weighted values are estimates.

select
    segments.segment_id,
    segments.line_id,
    segments.route_id,
    segments.direction_id,
    segments.from_station_id,
    segments.from_station_name,
    segments.to_station_id,
    segments.to_station_name,
    segments.segment_name,
    segments.branch_route_ids,
    segments.geometry,
    segments.geometry_source,
    reliability.traversals,
    reliability.service_dates_observed,
    reliability.avg_excess_travel_seconds,
    {{ format_duration('reliability.avg_excess_travel_seconds') }} as avg_excess_travel_label,
    reliability.median_scheduled_run_seconds,
    {{ format_duration('reliability.median_scheduled_run_seconds') }} as median_scheduled_run_label,
    reliability.median_run_seconds,
    {{ format_duration('reliability.median_run_seconds') }} as median_run_label,
    reliability.p90_run_seconds,
    {{ format_duration('reliability.p90_run_seconds') }} as p90_run_label,
    reliability.buffer_seconds,
    {{ format_duration('reliability.buffer_seconds') }} as buffer_label,
    reliability.buffer_index,
    reliability.has_rider_data,
    reliability.avg_weekday_rider_seconds_lost as avg_weekday_rider_time_lost_seconds,
    {{ format_duration('reliability.avg_weekday_rider_seconds_lost') }} as avg_weekday_rider_time_lost_label,
    reliability.avg_daily_rider_seconds_lost as avg_daily_rider_time_lost_seconds,
    {{ format_duration('reliability.avg_daily_rider_seconds_lost') }} as avg_daily_rider_time_lost_label,
    reliability.loss_rank,
    reliability.is_top_10,
    reliability.share_of_segment_loss,
    reliability.cause_class,
    reliability.cause_days,
    reliability.bias_seconds,
    {{ format_duration('reliability.bias_seconds') }} as bias_label,
    reliability.variability_iqr_seconds,
    {{ format_duration('reliability.variability_iqr_seconds') }} as variability_iqr_label,
    trend.recent_start_date,
    trend.recent_end_date,
    trend.prior_start_date,
    trend.prior_end_date,
    trend.runs_recent,
    trend.runs_prior,
    trend.avg_excess_seconds_recent,
    trend.avg_excess_seconds_prior,
    trend.delta_excess_seconds,
    {{ format_duration('trend.delta_excess_seconds') }} as delta_excess_label,
    trend.loss_share_recent,
    trend.loss_share_prior,
    trend.loss_share_change,
    trend.meets_volume_threshold,
    trend.is_getting_worse
from {{ ref('dim_segments') }} as segments
inner join {{ ref('mart_segment_reliability') }} as reliability on segments.segment_id = reliability.segment_id
inner join {{ ref('mart_segment_trend') }} as trend on segments.segment_id = trend.segment_id
order by segments.line_id, segments.direction_id, segments.from_stop_order, segments.segment_id
