{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per service_id, date and archive validity range (GTFS calendar_dates.txt):
-- exception_type 1 adds the service on that date, 2 removes it.

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

    with source as (

        select * from {{ source('gtfs', 'gtfs_calendar_dates') }}

    )

    select
        service_id,
        cast(strptime(cast(date as varchar), '%Y%m%d') as date) as service_date,
        cast(exception_type as integer) as exception_type,
        holiday_name,
        cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
        cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
    from source

{% endif %}
