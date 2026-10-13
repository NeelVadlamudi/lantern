-- Planned-change flags agree everywhere: each flagged line-day has a planned record in
-- mart_service_changes (a DIV timetable or a planned alert that affects the line), the daily
-- mart and the day views carry the same flag, and the tiles count the same line-days.
with flagged as (
    select
        route_id,
        service_date,
        is_planned_change
    from {{ ref('mart_planned_change_line_days') }}
),

records as (
    select distinct
        route_id,
        service_date
    from {{ ref('mart_service_changes') }}
    where is_planned and affects_line_day
)

select
    'flag without a planned record' as check_name,
    flagged.route_id,
    flagged.service_date
from flagged
left join records
    on flagged.route_id = records.route_id and flagged.service_date = records.service_date
where flagged.is_planned_change != (records.route_id is not null)

union all

select
    'daily mart flag differs' as check_name,
    flagged.route_id,
    flagged.service_date
from flagged
inner join {{ ref('mart_line_daily_reliability') }} as daily
    on flagged.route_id = daily.route_id and flagged.service_date = daily.service_date
where daily.is_planned_change != flagged.is_planned_change

union all

select
    'completeness flag differs' as check_name,
    flagged.route_id,
    flagged.service_date
from flagged
inner join {{ ref('mart_line_day_completeness') }} as completeness
    on flagged.route_id = completeness.scope_id and flagged.service_date = completeness.service_date
where completeness.is_planned_change != flagged.is_planned_change

union all

select
    'day metrics flag differs' as check_name,
    flagged.route_id,
    flagged.service_date
from flagged
inner join {{ ref('mart_line_day_metrics') }} as metrics
    on flagged.route_id = metrics.scope_id and flagged.service_date = metrics.service_date
where metrics.is_planned_change != flagged.is_planned_change

union all

select
    'tile count differs' as check_name,
    tiles.tile_id as route_id,
    null as service_date
from {{ ref('board_tiles') }} as tiles
where
    tiles.tile_id in ('late_trip_share', 'avg_trip_excess_seconds', 'long_gap_share')
    and cast(tiles.tile ->> 'planned_change_line_days' as bigint) != (
        select count(*)
        from flagged
        inner join {{ ref('mart_line_daily_reliability') }} as daily
            on flagged.route_id = daily.route_id and flagged.service_date = daily.service_date
        where flagged.is_planned_change
    )
