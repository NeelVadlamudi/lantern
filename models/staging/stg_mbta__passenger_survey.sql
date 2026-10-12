{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per aggregation level, service mode, reporting group, measure and category of
-- the MBTA 2025 System-Wide Passenger Survey. Shares and margins of error are 0 to 1.
-- Stored as a table and re-read from the remote file only on the first build, on --full-refresh
-- or with --vars '{refresh_reference: true}' (see clear_reference_table()).

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

    with source as (

        select * from {{ source('mbta_open_data', 'mbta_passenger_survey_2025') }}

    )

    select
        aggregation_level,
        service_mode,
        reporting_group,
        measure_group,
        measure,
        category,
        cast(weighted_percent as double) as weighted_share,
        cast(n as bigint) as respondents,
        cast(margin_of_error as double) as margin_of_error
    from source

{% endif %}
