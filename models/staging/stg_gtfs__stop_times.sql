{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per trip, stop sequence and archive version.
-- The yearly file is large, so only the rows the models need are kept: the representative trip
-- of each subway route pattern (for stop order).
-- Stored as a table and re-read from the remote file only on the first build, on --full-refresh
-- or with --vars '{refresh_reference: true}' (see clear_reference_table()).

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

    with representative_trips as (

        select distinct representative_trip_id as trip_id
        from {{ ref('stg_gtfs__route_patterns') }}
        where route_id in ('Red', 'Mattapan', 'Orange', 'Blue', 'Green-B', 'Green-C', 'Green-D', 'Green-E')

    ),

    source as (

        select * from {{ source('gtfs', 'gtfs_stop_times') }}
        where trip_id in (select representative_trips.trip_id from representative_trips)

    )

    select
        trip_id,
        stop_id,
        stop_sequence,
        cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
        cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
    from source

{% endif %}
