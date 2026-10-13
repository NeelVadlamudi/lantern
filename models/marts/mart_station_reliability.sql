-- Grain: one row per station, line (trunk line: Red, Orange, Blue, Green, Mattapan), day type
-- and service period, over the loaded window.
-- Reliability is measured on trains arriving at the station: excess travel on the segment into
-- the station and the trunk headway at the station. Rider exposure comes from average daily
-- fare-gate entries for the same station, line, day type and period (int_station_period_riders).
-- Gated entries exist only for gated stations, so has_rider_data is false for Green Line surface
-- stops and most Mattapan stops; those rows keep their reliability numbers but no rider weight.
-- Body in macros/station_reliability.sql (shared with mart_station_reliability_planned).

{{ station_reliability(split_planned=false) }}
