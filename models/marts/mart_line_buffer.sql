-- Grain: one row per line. Buffer time from mart_segment_reliability: the extra time beyond a
-- typical run to plan for so a segment is done on time 9 times out of 10 (p90 - median actual
-- run time). Line values weight each segment by its train runs:
--   avg_segment_buffer_seconds = sum(runs * buffer) / sum(runs)
--   buffer_index = sum(runs * buffer) / sum(runs * median run time)
-- so a buffer index of 0.25 means "plan about a quarter more than the typical run time".
-- Segment p90s do not all happen on the same trip, so adding them up along a trip overstates
-- the buffer for a whole trip; the line value is a per-segment average, not a trip total.

with segments as (

    select * from {{ ref('mart_segment_reliability') }}
    where traversals > 0

)

select
    cast(line_id as varchar) as line_id,
    cast(count(*) as integer) as segments,
    cast(sum(traversals) as bigint) as traversals,
    cast(sum(traversals * median_run_seconds) / sum(traversals) as double) as avg_segment_median_run_seconds,
    cast(sum(traversals * p90_run_seconds) / sum(traversals) as double) as avg_segment_p90_run_seconds,
    cast(sum(traversals * buffer_seconds) / sum(traversals) as double) as avg_segment_buffer_seconds,
    cast(sum(traversals * buffer_seconds) / sum(traversals * median_run_seconds) as double) as buffer_index,
    cast(max(buffer_seconds) as double) as max_segment_buffer_seconds,
    cast(arg_max(segment_name, buffer_seconds) as varchar) as max_buffer_segment_name
from segments
group by line_id
