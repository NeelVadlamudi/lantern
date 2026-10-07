{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per GTFS route id per archive version.
-- Stored as a table and re-read from the remote file only on the first build, on --full-refresh
-- or with --vars '{refresh_reference: true}' (see clear_reference_table()).

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

with source as (

    select * from {{ source('gtfs', 'gtfs_routes') }}

)

select
    route_id,
    route_long_name as route_name,
    route_short_name,
    route_type,
    replace(line_id, 'line-', '') as line_id,
    '#' || upper(route_color) as route_color_hex,
    '#' || upper(route_text_color) as route_text_color_hex,
    route_sort_order,
    cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
    cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
from source

{% endif %}
