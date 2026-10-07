-- Grain: one row per GTFS stop id per archive version (gtfs_active_date).
-- Includes stations (location_type 1), platforms (0) and entrances/nodes.

with source as (

    select * from {{ source('gtfs', 'gtfs_stops') }}

)

select
    stop_id,
    stop_name,
    stop_lat as latitude,
    stop_lon as longitude,
    nullif(parent_station, '') as parent_station_id,
    location_type,
    vehicle_type,
    wheelchair_boarding,
    municipality,
    platform_name,
    cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
    cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
from source
