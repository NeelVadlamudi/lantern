{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per route pattern per archive version.
-- Stored as a table and re-read from the remote file only on the first build, on --full-refresh
-- or with --vars '{refresh_reference: true}' (see clear_reference_table()).

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

with source as (

    select * from {{ source('gtfs', 'gtfs_route_patterns') }}

)

select
    route_pattern_id,
    route_id,
    cast(direction_id as integer) as direction_id,
    route_pattern_name,
    route_pattern_typicality,
    canonical_route_pattern = 1 as is_canonical,
    representative_trip_id,
    cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
    cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
from source

{% endif %}
