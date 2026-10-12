-- Completeness: trips_compared equals fct_trips per route and day, system rows equal the sum of
-- the routes, the flag follows the documented threshold, and every service date in the window
-- has scheduled trips (a date with no schedule means the GTFS calendar did not load for it).
with fact as (
    select
        route_id,
        service_date,
        count(*) filter (where compared_segments > 0) as trips_compared
    from {{ ref('fct_trips') }}
    group by route_id, service_date
),

routes_sum as (
    select
        service_date,
        sum(scheduled_trips) as scheduled_trips,
        sum(trips_compared) as trips_compared
    from {{ ref('mart_line_day_completeness') }}
    where scope_id != 'system'
    group by service_date
)

select
    'route trips_compared' as check_name,
    fact.route_id,
    fact.service_date
from fact
left join {{ ref('mart_line_day_completeness') }} as completeness
    on fact.route_id = completeness.scope_id and fact.service_date = completeness.service_date
where completeness.trips_compared is distinct from fact.trips_compared

union all

select
    'system equals sum of routes' as check_name,
    'system' as route_id,
    routes_sum.service_date
from routes_sum
inner join {{ ref('mart_line_day_completeness') }} as completeness
    on completeness.scope_id = 'system' and routes_sum.service_date = completeness.service_date
where
    completeness.scheduled_trips != routes_sum.scheduled_trips
    or completeness.trips_compared != routes_sum.trips_compared

union all

select
    'flag follows threshold' as check_name,
    scope_id as route_id,
    service_date
from {{ ref('mart_line_day_completeness') }}
where is_low_completeness != (trips_compared < {{ var('completeness_min_share') }} * scheduled_trips)

union all

select
    'no schedule for the date' as check_name,
    scope_id as route_id,
    service_date
from {{ ref('mart_line_day_completeness') }}
where scope_id = 'system' and scheduled_trips = 0
