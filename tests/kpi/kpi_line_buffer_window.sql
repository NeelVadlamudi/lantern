-- Line buffer window and run count: first_service_date / last_service_date are the first and
-- last dates with a compared run on the line in fct_segment_traversals, traversals equals the
-- compared runs over the line's segments in mart_segment_reliability, and the board file
-- carries the same values.
with expected as (
    select
        traversals.line_id,
        min(traversals.service_date) as first_service_date,
        max(traversals.service_date) as last_service_date
    from {{ ref('fct_segment_traversals') }} as traversals
    where traversals.is_compared
    group by traversals.line_id
),

runs as (
    select
        line_id,
        sum(traversals) as traversals
    from {{ ref('mart_segment_reliability') }}
    where traversals > 0
    group by line_id
)

select
    buffer.line_id,
    'mart window or runs' as check_name
from {{ ref('mart_line_buffer') }} as buffer
left join expected on buffer.line_id = expected.line_id
left join runs on buffer.line_id = runs.line_id
where
    buffer.first_service_date is distinct from expected.first_service_date
    or buffer.last_service_date is distinct from expected.last_service_date
    or buffer.traversals is distinct from runs.traversals

union all

select
    board.line_id,
    'board file differs' as check_name
from {{ ref('board_line_buffer') }} as board
inner join {{ ref('mart_line_buffer') }} as buffer on board.line_id = buffer.line_id
where
    board.first_service_date is distinct from buffer.first_service_date
    or board.last_service_date is distinct from buffer.last_service_date
    or board.traversals is distinct from buffer.traversals
