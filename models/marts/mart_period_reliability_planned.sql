-- Grain: one row per line (GTFS route), day type, service period and is_planned_change, over the
-- loaded window. Same measures as mart_period_reliability, split on whether the line-day had a
-- planned service change (mart_planned_change_line_days), so the time-of-day view can leave
-- planned line-days out. Body in macros/period_reliability.sql.

{{ period_reliability(split_planned=true) }}
