-- Grain: one row per parent station (place-*) on a subway canonical route pattern or seen in
-- LAMP data. Coordinates are WGS84 from GTFS stops.txt in the version active on the latest
-- loaded service date. route_ids lists the GTFS routes whose canonical pattern stops there.

with as_of as (

    select {{ gtfs_as_of_date() }} as as_of_date

),

stops as (

    select s.*
    from {{ ref('stg_gtfs__stops') }} as s
    cross join as_of
    where as_of.as_of_date between s.valid_from_date and s.valid_to_date

),

pattern_stations as (

    select
        station_id,
        string_agg(distinct route_id, ',' order by route_id) as route_ids,
        string_agg(distinct case when route_id like 'Green-%' then 'Green' else route_id end, ',')
            as line_ids
    from {{ ref('int_line_stop_sequence') }}
    group by station_id

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
