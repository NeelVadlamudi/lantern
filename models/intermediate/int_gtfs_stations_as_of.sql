-- Grain: one row per subway parent station, attributes as of gtfs_as_of_date().
-- attributes_valid_from is the first archive date on which the station's current combination of
-- attributes appeared. Coordinates are rounded to 5 decimals (about 1 m) so that re-exports that
-- only change the 6th decimal do not count as a change. This lets the timestamp-strategy
-- snapshot record the real GTFS change dates when it is replayed over past as-of dates.

with subway_stations as (

    select distinct coalesce(stops.parent_station_id, stop_times.stop_id) as station_id
    from {{ ref('stg_gtfs__stop_times') }} as stop_times
    inner join {{ ref('stg_gtfs__stops') }} as stops
        on
            stop_times.stop_id = stops.stop_id
            and stop_times.valid_from_date = stops.valid_from_date

),

versions as (

    select
        stops.stop_id as station_id,
        stops.stop_name as station_name,
        round(stops.latitude, 5) as latitude,
        round(stops.longitude, 5) as longitude,
        stops.municipality,
        stops.wheelchair_boarding,
        stops.valid_from_date,
        md5(concat_ws(
            '|', stops.stop_name, round(stops.latitude, 5), round(stops.longitude, 5),
            stops.municipality, stops.wheelchair_boarding
        )) as attribute_hash
    from {{ ref('stg_gtfs__stops') }} as stops
    inner join subway_stations
        on stops.stop_id = subway_stations.station_id
    where stops.valid_from_date <= {{ gtfs_as_of_date() }}

),

flagged as (

    select
        *,
        case
            when coalesce(lag(attribute_hash) over station_versions, '') != attribute_hash then 1
            else 0
        end as is_change
    from versions
    window station_versions as (partition by station_id order by valid_from_date)

),

islands as (

    select
        *,
        sum(is_change) over (partition by station_id order by valid_from_date) as island_id
    from flagged

),

current_island as (

    select
        *,
        min(valid_from_date) over (partition by station_id, island_id) as attributes_valid_from
    from islands
    qualify row_number() over (partition by station_id order by valid_from_date desc) = 1

)

select
    station_id,
    station_name,
    latitude,
    longitude,
    municipality,
    wheelchair_boarding,
    cast(attributes_valid_from as timestamp) as attributes_valid_from
from current_island
