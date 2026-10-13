{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/day_worst_segments.parquet'
    )
}}
-- Board file: the 3 segments with the most train delay (positive seconds) each day, per line
-- scope and for the whole subway (mart_segment_day_delay, day_rank 1 to 3), with the segment's
-- typical value for the same day type. Grain: one row per scope, service date and rank.

select
    delay.scope_id,
    delay.service_date,
    delay.day_type,
    delay.is_planned_change,
    delay.day_rank,
    delay.segment_id,
    segments.segment_name,
    delay.line_id,
    delay.direction_id,
    delay.from_station_id,
    segments.from_station_name,
    delay.to_station_id,
    segments.to_station_name,
    delay.runs_compared,
    delay.positive_excess_seconds,
    {{ format_duration('delay.positive_excess_seconds') }} as positive_excess_label,
    delay.net_excess_seconds,
    {{ format_duration('delay.net_excess_seconds') }} as net_excess_label,
    delay.positive_excess_per_run_seconds,
    delay.net_excess_per_run_seconds,
    delay.typical_days,
    delay.typical_median_positive_seconds,
    {{ format_duration('delay.typical_median_positive_seconds') }} as typical_median_positive_label,
    delay.typical_mean_positive_seconds,
    delay.diff_vs_median_seconds,
    {{ format_duration('delay.diff_vs_median_seconds') }} as diff_vs_median_label,
    delay.diff_vs_mean_seconds
from {{ ref('mart_segment_day_delay') }} as delay
inner join {{ ref('dim_segments') }} as segments on delay.segment_id = segments.segment_id
where delay.day_rank <= 3
order by delay.service_date, delay.scope_id, delay.day_rank
