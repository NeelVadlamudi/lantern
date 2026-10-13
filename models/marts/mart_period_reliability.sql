-- Grain: one row per line (GTFS route), day type and service period, over the loaded window.
-- Trip measures use matched trips; stop-level measures use every stop event.
-- Body in macros/period_reliability.sql (shared with mart_period_reliability_planned).

{{ period_reliability(split_planned=false) }}
