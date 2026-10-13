-- Grain: one row per line. Buffer time from mart_segment_reliability: the extra time beyond a
-- typical run to plan for so a segment is done on time 9 times out of 10 (p90 - median actual
-- run time). Line values weight each segment by its train runs:
--   avg_segment_buffer_seconds = sum(runs * buffer) / sum(runs)
--   buffer_index = sum(runs * buffer) / sum(runs * median run time)
-- so a buffer index of 0.25 means "plan about a quarter more than the typical run time".
-- Segment p90s do not all happen on the same trip, so adding them up along a trip overstates
-- the buffer for a whole trip; the line value is a per-segment average, not a trip total.
-- traversals = compared train runs over the line's segments (the run count behind the
-- weights). first_service_date / last_service_date = the first and last service dates with a
-- compared run on the line (fct_segment_traversals): the window the buffer is computed over.

with segments as (

    select * from {{ ref('mart_segment_reliability') }}
    where traversals > 0

),

service_window as (

    select
        line_id,
        min(service_date) as first_service_date,
        max(service_date) as last_service_date
    from {{ ref('fct_segment_traversals') }}
    where is_compared
    group by line_id

),

line_totals as (

    select
        line_id,
        count(*) as segments,
        sum(traversals) as traversals,
        sum(traversals * median_run_seconds) / sum(traversals) as avg_segment_median_run_seconds,
        sum(traversals * p90_run_seconds) / sum(traversals) as avg_segment_p90_run_seconds,
        sum(traversals * buffer_seconds) / sum(traversals) as avg_segment_buffer_seconds,
        sum(traversals * buffer_seconds) / sum(traversals * median_run_seconds) as buffer_index,
        max(buffer_seconds) as max_segment_buffer_seconds,
        arg_max(segment_name, buffer_seconds) as max_buffer_segment_name
    from segments
    group by line_id

)

select
    cast(line_totals.line_id as varchar) as line_id,
    cast(service_window.first_service_date as date) as first_service_date,
    cast(service_window.last_service_date as date) as last_service_date,
    cast(line_totals.segments as integer) as segments,
    cast(line_totals.traversals as bigint) as traversals,
    cast(line_totals.avg_segment_median_run_seconds as double) as avg_segment_median_run_seconds,
    cast(line_totals.avg_segment_p90_run_seconds as double) as avg_segment_p90_run_seconds,
    cast(line_totals.avg_segment_buffer_seconds as double) as avg_segment_buffer_seconds,
    cast(line_totals.buffer_index as double) as buffer_index,
    cast(line_totals.max_segment_buffer_seconds as double) as max_segment_buffer_seconds,
    cast(line_totals.max_buffer_segment_name as varchar) as max_buffer_segment_name
from line_totals
left join service_window on line_totals.line_id = service_window.line_id
