-- Bunched / gapped counts (SFMTA rules) in line_day_metrics and headway_adherence match a
-- recount from fct_trip_stop_events per route and day, and the system rows equal the sum of the
-- routes, and the Green rows of line_day_metrics the sum of the four branches. Exact (counts).
with fact as (
    select
        route_id,
        service_date,
        count(*) as departures_compared,
        count(*) filter (where headway_seconds < {{ var('bunched_max_seconds') }}) as bunched,
        count(*) filter (
            where headway_seconds > scheduled_headway_seconds + {{ var('gapped_extra_seconds') }}
        ) as gapped
    from {{ ref('fct_trip_stop_events') }}
    where has_headway_comparison
        and service_date >= (select min(date_day) from {{ ref('dim_dates') }})
    group by route_id, service_date
),

metrics as (
    select
        scope_id,
        service_date,
        max(value) filter (where measure = 'departures_compared') as departures_compared,
        max(value) filter (where measure = 'bunched_departures') as bunched,
        max(value) filter (where measure = 'gapped_departures') as gapped
    from {{ ref('mart_line_day_metrics') }}
    group by scope_id, service_date
),

hourly as (
    select
        scope_id,
        service_date,
        sum(departures_compared) as departures_compared,
        sum(bunched_departures) as bunched,
        sum(gapped_departures) as gapped
    from {{ ref('board_headway_adherence') }}
    group by scope_id, service_date
),

system_fact as (
    select
        'system' as route_id,
        service_date,
        sum(departures_compared) as departures_compared,
        sum(bunched) as bunched,
        sum(gapped) as gapped
    from fact
    group by service_date
),

green_fact as (
    select
        'Green' as route_id,
        service_date,
        sum(departures_compared) as departures_compared,
        sum(bunched) as bunched,
        sum(gapped) as gapped
    from fact
    where route_id like 'Green-%'
    group by service_date
),

expected as (
    select * from fact
    union all
    select * from system_fact
    union all
    select * from green_fact
)

select
    expected.route_id,
    expected.service_date
from expected
left join metrics on expected.route_id = metrics.scope_id and expected.service_date = metrics.service_date
left join hourly on expected.route_id = hourly.scope_id and expected.service_date = hourly.service_date
where
    metrics.bunched is distinct from expected.bunched
    or metrics.gapped is distinct from expected.gapped
    or metrics.departures_compared is distinct from expected.departures_compared
    or (
        expected.route_id != 'Green'
        and (
            hourly.bunched is distinct from expected.bunched
            or hourly.gapped is distinct from expected.gapped
            or hourly.departures_compared is distinct from expected.departures_compared
        )
    )
