{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/map_stations.parquet'
    )
}}
-- Board file: one row per station for the map (mart_station_overview).
-- station_id is the GTFS parent station id (place-*), the same id the MBTA V3 API uses for
-- stops, so live vehicle positions can be matched to it. route_ids is a list of V3 subway route
-- ids; cr_route_ids the Commuter Rail routes stopping there (mart_cr_route_stops); modes lists
-- both. Commuter Rail only stations are added with no subway measures (null).

with cr as (

    select
        station_id,
        any_value(station_name) as station_name,
        any_value(latitude) as latitude,
        any_value(longitude) as longitude,
        list(distinct route_id order by route_id) as cr_route_ids
    from {{ ref('mart_cr_route_stops') }}
    group by station_id

),

subway as (

    select
        station_id,
        station_name,
        latitude,
        longitude,
        string_split(route_ids, ',') as route_ids,
        string_split(line_ids, ',') as line_ids,
        trip_stop_events,
        has_rider_data,
        round(avg_daily_gated_entries, 1) as avg_daily_gated_entries,
        round(map_excess_seconds, 1) as map_excess_seconds,
        round(map_long_gap_share, 4) as map_long_gap_share,
        round(rider_weighted_excess_seconds, 1) as rider_weighted_excess_seconds,
        round(rider_weighted_long_gap_share, 4) as rider_weighted_long_gap_share,
        round(est_daily_entries_in_long_gaps, 0) as est_daily_entries_in_long_gaps,
        round(weekday_gated_entries, 0) as weekday_gated_entries,
        round(weekday_entries_in_long_gaps, 0) as weekday_entries_in_long_gaps
    from {{ ref('mart_station_overview') }}

)

select
    coalesce(subway.station_id, cr.station_id) as station_id,
    coalesce(subway.station_name, cr.station_name) as station_name,
    coalesce(subway.latitude, cr.latitude) as latitude,
    coalesce(subway.longitude, cr.longitude) as longitude,
    coalesce(subway.route_ids, []) as route_ids,
    coalesce(subway.line_ids, []) as line_ids,
    coalesce(cr.cr_route_ids, []) as cr_route_ids,
    list_filter(
        [
            case when subway.station_id is not null then 'subway' end,
            case when cr.station_id is not null then 'commuter_rail' end
        ],
        m -> m is not null
    ) as modes,
    subway.trip_stop_events,
    subway.has_rider_data,
    subway.avg_daily_gated_entries,
    subway.map_excess_seconds,
    subway.map_long_gap_share,
    subway.rider_weighted_excess_seconds,
    subway.rider_weighted_long_gap_share,
    subway.est_daily_entries_in_long_gaps,
    subway.weekday_gated_entries,
    subway.weekday_entries_in_long_gaps
from subway
full outer join cr on subway.station_id = cr.station_id
order by station_id
