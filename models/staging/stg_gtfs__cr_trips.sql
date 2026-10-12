{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per trip and archive validity range.
-- Commuter Rail: only the representative trips of canonical route patterns of the 13 CR- routes
-- (for stop order and track shapes on the map). Subway trips are in stg_gtfs__trips.
-- Stored as a table and re-read from the remote file only on the first build, on --full-refresh
-- or with --vars '{refresh_reference: true}' (see clear_reference_table()).

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

    with representative_trips as (

        select distinct representative_trip_id as trip_id
        from {{ ref('stg_gtfs__route_patterns') }}
        where route_id like 'CR-%' and is_canonical

    ),

    source as (

        select * from {{ source('gtfs', 'gtfs_trips') }}
        where trip_id in (select representative_trips.trip_id from representative_trips)

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

{% endif %}
