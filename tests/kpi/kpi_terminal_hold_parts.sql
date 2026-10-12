-- Terminal holds are kept as recorded; the positive and negative parts must add up to the total
-- and match the run-level data.
with daily as (
    select
        sum(terminal_hold_seconds_sum) as total,
        sum(terminal_hold_positive_seconds_sum) as positive_part,
        sum(terminal_hold_negative_seconds_sum) as negative_part,
        sum(terminal_hold_negative_runs) as negative_runs
    from {{ ref('mart_train_delay_daily') }}
),

runs as (
    select
        coalesce(sum(terminal_hold_seconds), 0) as total,
        count(*) filter (where terminal_hold_seconds < 0) as negative_runs
    from {{ ref('int_train_runs') }}
),

segments as (
    select
        sum(terminal_hold_seconds_sum) as total,
        sum(terminal_hold_positive_seconds_sum) + sum(terminal_hold_negative_seconds_sum) as parts
    from {{ ref('mart_segment_daily') }}
)

select 'daily parts' as failure from daily
where total != positive_part + negative_part or negative_part > 0
union all
select 'daily vs runs'
from daily
cross join runs
where daily.total != runs.total or daily.negative_runs != runs.negative_runs
union all
select 'segment parts' from segments
where total != parts
