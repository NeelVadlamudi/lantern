-- Grain: one row per trip and archive validity range (representative trips only; see the loader).

with source as (

    select * from {{ source('gtfs', 'gtfs_trips') }}

)

select
    trip_id,
    route_id,
    cast(direction_id as integer) as direction_id,
    shape_id,
    route_pattern_id,
    cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
    cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
from source
