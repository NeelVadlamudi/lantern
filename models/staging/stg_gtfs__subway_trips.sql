{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per subway trip and archive validity range (GTFS trips.txt, the eight subway
-- routes only), with its service_id, so scheduled trips can be counted per service date.

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

    with source as (

        select * from {{ source('gtfs', 'gtfs_trips') }}
        where route_id in ('Red', 'Mattapan', 'Orange', 'Blue', 'Green-B', 'Green-C', 'Green-D', 'Green-E')

    )

    select
        trip_id,
        route_id,
        service_id,
        cast(direction_id as integer) as direction_id,
        cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
        cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
    from source

{% endif %}
