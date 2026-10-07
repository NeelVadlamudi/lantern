{{ config(enabled=var('check_incremental', false)) }}
-- Incremental proof, step 2: every service date older than the reprocessing lookback
-- (last saved date - incremental_lookback_days) kept its row count and loaded_at, so it was not
-- rebuilt.
with saved as (
    select * from audit.incremental_state
    where service_date < (select max(service_date) from audit.incremental_state)
        - interval '{{ var("incremental_lookback_days") }} days'
),

now_state as (
    select service_date, count(*) as n_rows, max(loaded_at) as max_loaded_at
    from {{ ref('fct_trip_stop_events') }}
    group by service_date
)

select saved.service_date, saved.n_rows as rows_before, now_state.n_rows as rows_after,
    saved.max_loaded_at as loaded_before, now_state.max_loaded_at as loaded_after
from saved
left join now_state on saved.service_date = now_state.service_date
where now_state.n_rows is distinct from saved.n_rows
   or now_state.max_loaded_at is distinct from saved.max_loaded_at
