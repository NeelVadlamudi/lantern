-- The loaded LAMP window must have no gaps that dbt could have filled: every date between the
-- first and last loaded service date needs data, unless MBTA has not published that day (no
-- file in the LAMP index) or published it empty. Those days are recorded as gaps in health.json
-- by the daily run and re-checked on every run until a file with rows arrives. A gap here means
-- a published day failed to load or was skipped.
with loaded as (
    select distinct service_date from {{ ref('stg_lamp__subway_trip_stops') }}
),

index_files as (
    select
        cast(service_date as date) as service_date,
        cast(cast(last_modified as timestamptz) at time zone 'UTC' as timestamp) as last_modified_utc
    from {{ source('lamp', 'lamp_index') }}
),

published as (
    select index_files.service_date
    from index_files
    left join {{ lamp_empty_file_versions() }} as empty_files
        on
            index_files.service_date = empty_files.service_date
            and index_files.last_modified_utc = empty_files.last_modified_utc
    where empty_files.service_date is null
)

select d.date_day as missing_service_date
from {{ ref('dim_dates') }} as d
left join loaded on d.date_day = loaded.service_date
where
    loaded.service_date is null
    and d.date_day in (select published.service_date from published)
