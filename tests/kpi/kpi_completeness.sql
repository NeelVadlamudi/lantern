-- Completeness: trips_compared equals the scheduled trip ids with a compared run in
-- fct_trips per schedule route and day (runs split matched / unmatched),
-- completeness_share never exceeds 1, system rows equal the sum of the routes, the flag
-- follows the documented threshold, and every service date in the window
-- has scheduled trips (a date with no schedule means the GTFS calendar did not load for it).
with scheduled_compared as (
    -- by the schedule's route: LAMP sometimes records a Green trip under another branch
    select
        scheduled.route_id,
        scheduled.service_date,
        count(distinct scheduled.trip_id) as trips_compared
    from {{ ref('int_scheduled_subway_trips') }} as scheduled
    inner join {{ ref('fct_trips') }} as trips
        on scheduled.service_date = trips.service_date and scheduled.trip_id = trips.trip_id
    where trips.compared_segments > 0
        and trips.service_date >= (select min(date_day) from {{ ref('dim_dates') }})
    group by scheduled.route_id, scheduled.service_date
),

runs as (
    select
        route_id,
        service_date,
        count(*) filter (where compared_segments > 0 and is_matched_trip) as matched_runs_compared,
        count(*) filter (where compared_segments > 0 and not is_matched_trip) as unmatched_runs_compared
    from {{ ref('fct_trips') }}
    where service_date >= (select min(date_day) from {{ ref('dim_dates') }})
    group by route_id, service_date
),

fact as (
    select
        coalesce(runs.route_id, scheduled_compared.route_id) as route_id,
        coalesce(runs.service_date, scheduled_compared.service_date) as service_date,
        coalesce(scheduled_compared.trips_compared, 0) as trips_compared,
        coalesce(runs.matched_runs_compared, 0) as matched_runs_compared,
        coalesce(runs.unmatched_runs_compared, 0) as unmatched_runs_compared
    from runs
    full outer join scheduled_compared
        on runs.route_id = scheduled_compared.route_id and runs.service_date = scheduled_compared.service_date
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
    or completeness.matched_runs_compared is distinct from fact.matched_runs_compared
    or completeness.unmatched_runs_compared is distinct from fact.unmatched_runs_compared

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

union all

select
    'completeness above 1' as check_name,
    scope_id as route_id,
    service_date
from {{ ref('mart_line_day_completeness') }}
where completeness_share > 1 or matched_trips_compared > scheduled_trips
