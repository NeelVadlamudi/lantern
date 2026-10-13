-- Grain: one row per station, line, day type, service period and is_planned_change, over the
-- loaded window. Same measures as mart_station_reliability, split on whether the line had a
-- planned service change that day (mart_planned_change_scope_days, scope_type 'line'), so the
-- station views can leave planned days out. Body in macros/station_reliability.sql.

{{ station_reliability(split_planned=true) }}
