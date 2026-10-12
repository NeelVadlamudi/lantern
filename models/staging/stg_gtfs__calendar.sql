{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per service_id and archive validity range (GTFS calendar.txt): the weekdays the
-- service runs on between start_date and end_date. Re-read like the other GTFS reference tables.

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

    with source as (

        select * from {{ source('gtfs', 'gtfs_calendar') }}

    )

    select
        service_id,
        cast(monday = 1 as boolean) as runs_monday,
        cast(tuesday = 1 as boolean) as runs_tuesday,
        cast(wednesday = 1 as boolean) as runs_wednesday,
        cast(thursday = 1 as boolean) as runs_thursday,
        cast(friday = 1 as boolean) as runs_friday,
        cast(saturday = 1 as boolean) as runs_saturday,
        cast(sunday = 1 as boolean) as runs_sunday,
        cast(strptime(cast(start_date as varchar), '%Y%m%d') as date) as start_date,
        cast(strptime(cast(end_date as varchar), '%Y%m%d') as date) as end_date,
        cast(strptime(cast(gtfs_active_date as varchar), '%Y%m%d') as date) as valid_from_date,
        cast(strptime(cast(gtfs_end_date as varchar), '%Y%m%d') as date) as valid_to_date
    from source

{% endif %}
