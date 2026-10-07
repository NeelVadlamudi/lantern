-- board_data.json coverage.system counts equal counts taken straight from the fact, and the
-- by-route rows (8 routes) add up to the same event total.
with fact as (
    select
        count(*) as trip_stop_events,
        count(*) filter (where coalesce(scheduled_run_seconds, 0) <= 0) as without_scheduled_travel,
        count(*) filter (where coalesce(scheduled_headway_seconds, 0) <= 0) as without_scheduled_headway,
        count(*) filter (
            where coalesce(scheduled_run_seconds, 0) <= 0 and coalesce(scheduled_headway_seconds, 0) <= 0
        ) as without_any_schedule
    from {{ ref('fct_trip_stop_events') }}
),

board as (
    select
        cast(coverage -> '$.system.trip_stop_events' as bigint) as trip_stop_events,
        cast(coverage -> '$.system.without_scheduled_travel' as bigint) as without_scheduled_travel,
        cast(coverage -> '$.system.without_scheduled_headway' as bigint) as without_scheduled_headway,
        cast(coverage -> '$.system.without_any_schedule' as bigint) as without_any_schedule,
        json_array_length(coverage -> '$.by_route') as n_routes,
        list_sum(cast(json_extract(coverage, '$.by_route[*].trip_stop_events') as bigint[])) as by_route_events
    from {{ ref('board_payload') }}
)

select
    board.*,
    fact.*
from board
cross join fact
where
    board.trip_stop_events != fact.trip_stop_events
    or board.without_scheduled_travel != fact.without_scheduled_travel
    or board.without_scheduled_headway != fact.without_scheduled_headway
    or board.without_any_schedule != fact.without_any_schedule
    or board.n_routes != 8
    or board.by_route_events != fact.trip_stop_events
