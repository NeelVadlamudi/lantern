-- The daily line mart must account for every fact row and every trip, per day.
with fact as (
    select
        service_date,
        count(*) as events,
        count(distinct trip_key) as trips
    from {{ ref('fct_trip_stop_events') }}
    -- the facts keep dates before the reporting window (dim_dates); the marts do not
    where service_date >= (select min(date_day) from {{ ref('dim_dates') }})
    group by service_date
),

mart as (
    select
        service_date,
        sum(trip_stop_events) as events,
        sum(trips) as trips
    from {{ ref('mart_line_daily_reliability') }}
    group by service_date
)

select
    fact.service_date,
    fact.events,
    mart.events as mart_events,
    fact.trips,
    mart.trips as mart_trips
from fact
full outer join mart on fact.service_date = mart.service_date
where fact.events is distinct from mart.events or fact.trips is distinct from mart.trips
