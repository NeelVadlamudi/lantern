-- Every service date the LAMP index lists from the first loaded date to the end of the window
-- (lamp_end_date, else yesterday in Boston) must have rows. An empty or truncated file for a day,
-- including the last day, otherwise just shortens the window: dim_dates stops at the last date
-- with rows, so the gap test cannot see it. A file that was checked and has no rows (MBTA
-- published the day empty) is a recorded gap, not a failed load, and is left out.
{%- set end_date = var('lamp_end_date', none) %}
with loaded as (
    select distinct service_date
    from {{ ref('stg_lamp__subway_trip_stops') }}
),

listed as (
    select distinct cast(service_date as date) as service_date
    from {{ source('lamp', 'lamp_index') }}
    where (
        cast(service_date as date),
        cast(cast(last_modified as timestamptz) at time zone 'UTC' as timestamp)
    ) not in (
        select (empty_files.service_date, empty_files.last_modified_utc)
        from {{ lamp_empty_file_versions() }} as empty_files
    )
)

select listed.service_date as listed_but_not_loaded
from listed
left join loaded on listed.service_date = loaded.service_date
where
    loaded.service_date is null
    and listed.service_date >= (select min(loaded_dates.service_date) from loaded as loaded_dates)
    and listed.service_date <= {% if end_date %}date '{{ end_date }}'{% else %}
        cast(now() at time zone 'America/New_York' as date) - 1{% endif %}
