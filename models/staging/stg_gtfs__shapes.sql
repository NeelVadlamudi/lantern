-- Grain: one row per shape point and archive validity range.

with source as (

    select * from {{ source('gtfs', 'gtfs_shapes') }}

)

select
    shape_id,
    shape_pt_sequence as shape_point_sequence,
    shape_pt_lat as latitude,
    shape_pt_lon as longitude,
    cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
    cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
from source
