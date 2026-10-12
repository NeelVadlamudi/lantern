{{ config(severity='warn') }}
-- Stop-to-stop run times over var('travel_outlier_seconds') (default 30 minutes): held trains,
-- disruptions or data gaps. They are kept in every travel measure and flagged in the fact
-- (is_travel_outlier); counted here so the number is visible in every run.
select
    trip_stop_event_key,
    actual_run_seconds
from {{ ref('fct_trip_stop_events') }}
where is_travel_outlier
