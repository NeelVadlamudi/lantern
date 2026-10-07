{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per shape point and archive validity range.
-- The yearly file is large, so only the rows the models need are kept: the shapes of
-- representative trips of subway route patterns.
-- Stored as a table and re-read from the remote file only on the first build, on --full-refresh
-- or with --vars '{refresh_reference: true}' (see clear_reference_table()).

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

with needed_shapes as (

    select distinct shape_id
    from {{ ref('stg_gtfs__trips') }}

),

source as (

    select * from {{ source('gtfs', 'gtfs_shapes') }}
    where shape_id in (select needed_shapes.shape_id from needed_shapes)

)

select
    shape_id,
    shape_pt_sequence as shape_point_sequence,
    shape_pt_lat as latitude,
    shape_pt_lon as longitude,
    cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
    cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
from source

{% endif %}
