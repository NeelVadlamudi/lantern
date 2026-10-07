-- Grain: one row per trip, stop sequence and archive version
-- (representative trips of subway route patterns only; see the loader).

with source as (

    select * from {{ source('gtfs', 'gtfs_stop_times') }}

)

select
    trip_id,
    stop_id,
    stop_sequence,
    cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
    cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
from source
