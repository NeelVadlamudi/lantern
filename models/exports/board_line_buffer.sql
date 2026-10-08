{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_buffer.parquet'
    )
}}
-- Board file: buffer time per line (mart_line_buffer). Grain: one row per line.
-- Exact seconds plus labels.

with line_order as (
    select
        line_id,
        min(display_order) as display_order
    from {{ ref('dim_routes') }}
    group by line_id
)

select
    line_buffer.line_id,
    line_buffer.segments,
    line_buffer.traversals,
    line_buffer.avg_segment_median_run_seconds,
    {{ format_duration('line_buffer.avg_segment_median_run_seconds') }} as avg_segment_median_run_label,
    line_buffer.avg_segment_p90_run_seconds,
    {{ format_duration('line_buffer.avg_segment_p90_run_seconds') }} as avg_segment_p90_run_label,
    line_buffer.avg_segment_buffer_seconds,
    {{ format_duration('line_buffer.avg_segment_buffer_seconds') }} as avg_segment_buffer_label,
    line_buffer.buffer_index,
    line_buffer.max_segment_buffer_seconds,
    {{ format_duration('line_buffer.max_segment_buffer_seconds') }} as max_segment_buffer_label,
    line_buffer.max_buffer_segment_name
from {{ ref('mart_line_buffer') }} as line_buffer
inner join line_order on line_buffer.line_id = line_order.line_id
order by line_order.display_order
