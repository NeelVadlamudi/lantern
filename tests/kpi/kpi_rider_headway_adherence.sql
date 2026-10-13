-- Rider-weighted headway adherence: shares lie in [0, 1], riders within the allowance never
-- exceed riders, Green Line trunk departures appear only in Green scopes, and the departure
-- share is recomputed from fct_trip_stop_events with T = greatest(H, 180 s) at trunk stations
-- and H elsewhere, on line-days without a planned change.
with trunk as (
    select station_id
    from {{ ref('int_line_stop_sequence') }}
    where route_id like 'Green-%'
    group by station_id
    having count(distinct route_id) >= 2
),

events as (
    select
        events.route_id,
        dates.day_type,
        events.service_period_id,
        events.headway_seconds
        <= case
            when events.line_id = 'Green' and events.station_id in (select trunk.station_id from trunk)
                then greatest(events.scheduled_headway_seconds, {{ var('green_trunk_min_allowance_seconds') }})
            else events.scheduled_headway_seconds
        end as is_within
    from {{ ref('fct_trip_stop_events') }} as events
    inner join {{ ref('dim_dates') }} as dates on events.service_date = dates.date_day
    inner join {{ ref('mart_planned_change_line_days') }} as planned
        on events.route_id = planned.route_id and events.service_date = planned.service_date
    where
        events.has_headway_comparison
        and events.headway_seconds > 0
        and events.scheduled_headway_seconds > 0
        and not planned.is_planned_change
),

expected as (
    select
        route_id,
        day_type,
        service_period_id,
        count(*) as departures,
        avg(cast(is_within as int)) as departure_share
    from events
    group by route_id, day_type, service_period_id
)

select
    'share out of range' as check_name,
    scope_id,
    day_type,
    service_period_id
from {{ ref('mart_rider_headway_adherence') }}
where
    rider_weighted_share not between 0 and 1
    or unweighted_share not between 0 and 1
    or departure_share not between 0 and 1
    or est_riders_within_allowance > est_riders * (1 + 1e-12)

union all

select
    'trunk departures outside Green' as check_name,
    scope_id,
    day_type,
    service_period_id
from {{ ref('mart_rider_headway_adherence') }}
where departures_at_green_trunk > 0 and scope_id not like 'Green%' and scope_id != 'system'

union all

select
    'departure share' as check_name,
    expected.route_id as scope_id,
    expected.day_type,
    expected.service_period_id
from expected
left join {{ ref('mart_rider_headway_adherence') }} as adherence
    on
        expected.route_id = adherence.scope_id
        and expected.day_type = adherence.day_type
        and expected.service_period_id = adherence.service_period_id
where
    adherence.departures is distinct from expected.departures
    or abs(adherence.departure_share - expected.departure_share) > 1e-12
