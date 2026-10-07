{{ config(enabled=var('check_incremental', false)) }}
-- Incremental proof, step 1: the fact now has a service date newer than any in
-- audit.incremental_state (saved by `dbt run-operation save_incremental_state` before the build).
select max_before, max_after
from (
    select
        (select max(service_date) from audit.incremental_state) as max_before,
        (select max(service_date) from {{ ref('fct_trip_stop_events') }}) as max_after
)
where max_after is null or max_after <= max_before
