-- Grain: one row per official Freedom Trail site (seed freedom_trail_sites), with the nearest
-- station: subway stations in dim_stations and Commuter Rail stations on the canonical patterns in
-- mart_cr_route_stops (a station served by both appears once, with both modes).
-- distance_m is the great-circle (haversine) distance in metres between the site point and the
-- station point (GTFS parent station coordinates), using a mean Earth radius of 6,371,008.8 m.
-- It is straight-line distance, not a walking route, and is stored exact (not rounded).
-- est_walk_seconds is an estimate: distance_m divided by the walking speed in the var
-- walk_speed_m_per_s (default 1.4 m/s). A walking route is usually longer than a straight line.
-- Ties on distance go to the lower station_id so the result is repeatable.

with sites as (

    select
        site_order,
        site_name,
        latitude,
        longitude,
        source_url,
        note
    from {{ ref('freedom_trail_sites') }}

),

subway_stations as (

    select
        station_id,
        station_name,
        latitude,
        longitude,
        route_ids,
        line_ids
    from {{ ref('dim_stations') }}
    where latitude is not null and longitude is not null

),

cr_stations as (

    select
        station_id,
        any_value(station_name) as station_name,
        any_value(latitude) as latitude,
        any_value(longitude) as longitude,
        string_agg(distinct route_id, ',' order by route_id) as cr_route_ids
    from {{ ref('mart_cr_route_stops') }}
    where latitude is not null and longitude is not null
    group by station_id

),

stations as (

    select
        coalesce(subway.station_id, cr.station_id) as station_id,
        coalesce(subway.station_name, cr.station_name) as station_name,
        coalesce(subway.latitude, cr.latitude) as latitude,
        coalesce(subway.longitude, cr.longitude) as longitude,
        concat_ws(',', subway.route_ids, cr.cr_route_ids) as route_ids,
        subway.line_ids,
        concat_ws(
            ',',
            case when subway.station_id is not null then 'subway' end,
            case when cr.station_id is not null then 'commuter_rail' end
        ) as modes
    from subway_stations as subway
    full outer join cr_stations as cr on subway.station_id = cr.station_id

),

site_station_distances as (

    select
        sites.site_order,
        sites.site_name,
        sites.latitude,
        sites.longitude,
        sites.source_url,
        sites.note,
        stations.station_id,
        stations.station_name,
        stations.route_ids,
        stations.line_ids,
        stations.modes,
        2 * 6371008.8 * asin(sqrt(
            power(sin(radians(stations.latitude - sites.latitude) / 2), 2)
            + cos(radians(sites.latitude)) * cos(radians(stations.latitude))
            * power(sin(radians(stations.longitude - sites.longitude) / 2), 2)
        )) as distance_m
    from sites
    cross join stations

),

nearest as (

    select *
    from site_station_distances
    qualify row_number() over (
            partition by site_order
            order by distance_m, station_id
        ) = 1

)

select
    cast(site_order as integer) as site_order,
    cast(site_name as varchar) as site_name,
    cast(latitude as double) as latitude,
    cast(longitude as double) as longitude,
    cast(station_id as varchar) as nearest_stop_id,
    cast(station_name as varchar) as nearest_stop_name,
    cast(route_ids as varchar) as nearest_stop_route_ids,
    cast(line_ids as varchar) as nearest_stop_line_ids,
    cast(modes as varchar) as nearest_stop_modes,
    cast(distance_m as double) as distance_m,
    cast(distance_m / {{ var('walk_speed_m_per_s', 1.4) }} as double) as est_walk_seconds,
    cast({{ var('walk_speed_m_per_s', 1.4) }} as double) as walk_speed_m_per_s,
    cast(source_url as varchar) as source_url,
    cast(note as varchar) as note
from nearest
