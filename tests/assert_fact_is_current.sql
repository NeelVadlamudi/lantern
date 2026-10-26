{{
    config(
        enabled=not var('use_sample', false),
        severity='error',
        warn_if='>0',
        error_if='>1'
    )
}}
-- Freshness of what was built (the source freshness check covers what MBTA has published).
-- One row per day the latest loaded service date is behind beyond the normal one-day lag:
-- warn when the data is more than 2 days old, error when more than 3 (no new service date for
-- three days in a row). One or two days MBTA has not published yet only warn; the board keeps
-- updating with the days that are there.
with lag_days as (
    select cast(now() at time zone 'America/New_York' as date) - max(service_date) as days_behind
    from {{ ref('fct_trip_stop_events') }}
)

select gs.generate_series as day_over
from lag_days
cross join generate_series(3, greatest(lag_days.days_behind, 2)) as gs
