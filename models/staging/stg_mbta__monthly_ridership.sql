{{
    config(
        materialized='incremental',
        on_schema_change='fail',
        pre_hook="{{ clear_reference_table() }}"
    )
}}

-- Grain: one row per month, day type and mode/line.
-- Stored as a table and re-read from the remote file only on the first build, on --full-refresh
-- or with --vars '{refresh_reference: true}' (see clear_reference_table()).

{% if keep_reference_table() %}

    select * from {{ this }}
    where false

{% else %}

with source as (

    select * from {{ source('mbta_open_data', 'mbta_monthly_ridership') }}

)

select
    cast(strptime(left(month_of_service, 10), '%Y/%m/%d') as date) as month_start_date,
    lower(daytype) as day_type,
    cast(daycount as integer) as day_count,
    route_or_line,
    cast(ridership_total as bigint) as ridership_total,
    cast(ridership_average as bigint) as ridership_average_per_day
from source

{% endif %}
