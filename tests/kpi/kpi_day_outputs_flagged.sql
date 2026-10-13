-- Every line-day output carries the planned-change flag of its scope and day
-- (mart_planned_change_scope_days): the daily line file, the day metrics, the hour heatmap, the
-- delay histogram, train delay by line and the system daily files. Returns rows that disagree.
with planned as (
    select
        scope_id,
        service_date,
        is_planned_change
    from {{ ref('mart_planned_change_scope_days') }}
    where scope_type = 'route'
),

outputs as (
    select
        'line_daily' as output_name,
        route_id as scope_id,
        service_date,
        is_planned_change
    from {{ ref('board_line_daily') }}
    union all
    select
        'line_day_metrics' as output_name,
        scope_id,
        service_date,
        is_planned_change
    from {{ ref('board_line_day_metrics') }}
    union all
    select
        'line_hour_heatmap' as output_name,
        scope_id,
        service_date,
        is_planned_change
    from {{ ref('board_line_hour_heatmap') }}
    union all
    select
        'delay_histogram' as output_name,
        scope_id,
        service_date,
        is_planned_change
    from {{ ref('board_delay_histogram') }}
    union all
    select
        'train_delay_by_line' as output_name,
        route_id as scope_id,
        service_date,
        is_planned_change
    from {{ ref('board_train_delay_by_line') }}
    where service_date is not null
    union all
    select
        'train_delay_daily' as output_name,
        'system' as scope_id,
        service_date,
        is_planned_change
    from {{ ref('board_train_delay_daily') }}
    union all
    select
        'rider_time_lost_daily' as output_name,
        'system' as scope_id,
        service_date,
        is_planned_change
    from {{ ref('board_rider_time_lost_daily') }}
    union all
    select
        'headway_adherence' as output_name,
        scope_id,
        service_date,
        is_planned_change
    from {{ ref('board_headway_adherence') }}
)

select
    outputs.output_name,
    outputs.scope_id,
    outputs.service_date
from outputs
left join planned
    on outputs.scope_id = planned.scope_id and outputs.service_date = planned.service_date
where outputs.is_planned_change is null
    or outputs.is_planned_change != coalesce(planned.is_planned_change, false)
