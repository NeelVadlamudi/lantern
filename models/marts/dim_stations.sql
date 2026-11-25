-- Grain: one row per parent station (place-*) on a subway canonical route pattern or seen in
-- LAMP data. Coordinates are WGS84 from GTFS stops.txt in the version active on the latest
-- loaded service date. route_ids lists the GTFS routes whose canonical pattern stops there.
--
-- A station can leave the GTFS feed mid-window while its LAMP rows are still in the window
-- (Fairbanks Street, place-fbkst: GTFS coverage ended 2026-11-23, LAMP reported it through
-- that day, and the board still shows those days). Such a station keeps the last name,
-- coordinates and pattern membership GTFS published for it, so the map can still place it.

with as_of as (

    select {{ gtfs_as_of_date() }} as as_of_date

),

stops as (

    -- Newest GTFS version that had started by the as-of date, not the version containing it:
    -- a retired station has no containing version, and the strict filter left its name and
    -- coordinates null. Current stations are unaffected (their newest started version is the
    -- containing one).
    select s.*
    from {{ ref('stg_gtfs__stops') }} as s
    cross join as_of
    where s.valid_from_date <= as_of.as_of_date
    qualify row_number() over (
        partition by s.stop_id
        order by s.valid_from_date desc, s.valid_to_date desc
    ) = 1

),

current_patterns as (

    select
        station_id,
        string_agg(distinct route_id, ',' order by route_id) as route_ids,
        string_agg(
            distinct case when route_id like 'Green-%' then 'Green' else route_id end, ','
            order by case when route_id like 'Green-%' then 'Green' else route_id end
        ) as line_ids
    from {{ ref('int_line_stop_sequence') }}
    group by station_id

),

reporting_window as (

    select
        (select max(service_date) from {{ ref('stg_lamp__subway_trip_stops') }})
            - {{ var('reporting_window_days') - 1 }} as window_start_date,
        (select a.as_of_date from as_of as a) as window_end_date

),

window_patterns as (

    select rp.*
    from {{ ref('stg_gtfs__route_patterns') }} as rp
    cross join reporting_window as w
    where rp.is_canonical
        and rp.route_id in (select ld.route_id from {{ ref('line_display') }} as ld)
        and rp.valid_from_date <= w.window_end_date
        and rp.valid_to_date >= w.window_start_date

),

window_stop_times as (

    select st.*
    from {{ ref('stg_gtfs__stop_times') }} as st
    cross join reporting_window as w
    where st.valid_from_date <= w.window_end_date
        and st.valid_to_date >= w.window_start_date

),

window_platforms as (

    select
        s.stop_id,
        s.parent_station_id
    from {{ ref('stg_gtfs__stops') }} as s
    cross join reporting_window as w
    where s.valid_from_date <= w.window_end_date
        and s.valid_to_date >= w.window_start_date

),

window_pattern_stations as (

    -- Canonical-pattern stations in any GTFS version that overlaps the reporting window.
    -- The distinct string_agg washes out the fan-out from several versions of one platform.
    select
        coalesce(window_platforms.parent_station_id, window_stop_times.stop_id) as station_id,
        string_agg(
            distinct window_patterns.route_id, ',' order by window_patterns.route_id
        ) as route_ids,
        string_agg(
            distinct case
                when window_patterns.route_id like 'Green-%' then 'Green'
                else window_patterns.route_id
            end,
            ','
            order by case
                when window_patterns.route_id like 'Green-%' then 'Green'
                else window_patterns.route_id
            end
        ) as line_ids
    from window_patterns
    inner join window_stop_times
        on window_patterns.representative_trip_id = window_stop_times.trip_id
    left join window_platforms
        on window_stop_times.stop_id = window_platforms.stop_id
    group by station_id

),

pattern_stations as (

    -- Current patterns win; the window set only adds stations that left the network
    -- mid-window, with the routes that stopped there while they were in the window.
    select
        coalesce(current_patterns.station_id, window_pattern_stations.station_id) as station_id,
        coalesce(current_patterns.route_ids, window_pattern_stations.route_ids) as route_ids,
        coalesce(current_patterns.line_ids, window_pattern_stations.line_ids) as line_ids
    from current_patterns
    full outer join window_pattern_stations
        on current_patterns.station_id = window_pattern_stations.station_id

),

observed_stations as (

    select distinct station_id
    from {{ ref('stg_lamp__subway_trip_stops') }}
    where station_id is not null

),

all_stations as (

    select station_id from pattern_stations
    union
    select station_id from observed_stations

)

select
    {{ dbt_utils.generate_surrogate_key(['all_stations.station_id']) }} as station_key,
    cast(all_stations.station_id as varchar) as station_id,
    cast(stops.stop_name as varchar) as station_name,
    cast(stops.latitude as double) as latitude,
    cast(stops.longitude as double) as longitude,
    cast(stops.municipality as varchar) as municipality,
    cast(stops.wheelchair_boarding = 1 as boolean) as is_wheelchair_accessible,
    cast(pattern_stations.route_ids as varchar) as route_ids,
    cast(pattern_stations.line_ids as varchar) as line_ids,
    pattern_stations.station_id is not null as is_on_canonical_pattern,
    all_stations.station_id in (select o.station_id from observed_stations as o) as is_observed_in_lamp
from all_stations
left join stops
    on all_stations.station_id = stops.stop_id
left join pattern_stations
    on all_stations.station_id = pattern_stations.station_id
