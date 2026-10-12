{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per source row: service date, route, line or branch name and peak/off-peak.
-- Before 2025-03-24 the Newburyport/Rockport and Providence/Stoughton lines have two rows per date
-- and period under the same name (one per branch, with different counts); both are kept, so the
-- key covers every column. Counts are whole trips, kept apart (numerators and denominators).
-- Stored as a table and re-read from the remote file only on the first build, on --full-refresh
-- or with --vars '{refresh_reference: true}' (see clear_reference_table()).

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

    with source as (

        select * from {{ source('mbta_open_data', 'mbta_cr_reliability') }}

    )

    select
        {{ dbt_utils.generate_surrogate_key([
            'service_date', 'gtfs_route_id', 'gtfs_route_long_name', 'peak_offpeak_ind', 'metric_type',
            'otp_numerator', 'otp_denominator', 'cancelled_numerator'
        ]) }} as cr_reliability_row_key,
        cast(strptime(service_date, '%m/%d/%Y') as date) as service_date,
        gtfs_route_id as source_route_id,
        gtfs_route_long_name as source_line_name,
        peak_offpeak_ind as peak_offpeak,
        metric_type,
        cast(otp_numerator as bigint) as on_time_trips,
        cast(otp_denominator as bigint) as counted_trips,
        cast(cancelled_numerator as bigint) as cancelled_trips
    from source

{% endif %}
