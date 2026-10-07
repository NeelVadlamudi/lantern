{{ config(severity='warn') }}
-- Stop-to-stop run times over var('travel_outlier_seconds') (default 30 minutes) are treated as
-- data errors or held trains and kept out of travel metrics. Counted here so the number is visible.
select
    trip_stop_event_key,
    actual_run_seconds
from {{ ref('fct_trip_stop_events') }}
where is_travel_outlier
