{{ config(enabled=var('check_incremental', false)) }}
-- Incremental proof, step 3: fact rows per service date equal staging rows, so the delete+insert
-- dropped and doubled nothing.
with fact as (
    select service_date, count(*) as n_rows from {{ ref('fct_trip_stop_events') }} group by 1
),

staged as (
    select service_date, count(*) as n_rows from {{ ref('stg_lamp__subway_trip_stops') }} group by 1
)

select coalesce(fact.service_date, staged.service_date) as service_date,
    fact.n_rows as fact_rows, staged.n_rows as staging_rows
from fact
full outer join staged on fact.service_date = staged.service_date
where fact.n_rows is distinct from staged.n_rows
