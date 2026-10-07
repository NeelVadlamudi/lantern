{{ config(severity='warn') }}
-- Scheduled arrival-to-arrival spans below zero come from schedules matched to ADDED trips or to
-- trips that ran out of order. They are excluded from travel metrics (has_travel_comparison is
-- false); this test counts them so the number shows up in every build.
select
    trip_stop_event_key,
    scheduled_run_seconds
from {{ ref('fct_trip_stop_events') }}
where scheduled_run_seconds < 0
