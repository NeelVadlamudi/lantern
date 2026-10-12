{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per service date and Commuter Rail line name. estimated_boardings is the MBTA's
-- own estimate (scaled conductor counts), not a count this project makes.
-- Stored as a table and re-read from the remote file only on the first build, on --full-refresh
-- or with --vars '{refresh_reference: true}' (see clear_reference_table()).

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

    with source as (

        select * from {{ source('mbta_open_data', 'mbta_cr_boardings') }}

    )

    select
        cast(servicedate as date) as service_date,
        line as source_line_name,
        cast(estimated_boardings as double) as estimated_boardings
    from source

{% endif %}
