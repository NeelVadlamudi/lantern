-- Late-arriving data: LAMP sometimes republishes a service date's file after it was loaded.
-- lamp_files_to_load() re-reads such dates on the next incremental run; this test fails when a
-- loaded date's file in the index is newer than the time it was loaded, i.e. a republished file
-- was not picked up.
with loaded as (
    select
        service_date,
        max(_loaded_at) as loaded_at
    from {{ ref('stg_lamp__subway_trip_stops') }}
    group by service_date
),

index_files as (
    select
        cast(service_date as date) as service_date,
        cast(cast(last_modified as timestamptz) at time zone 'UTC' as timestamp) as last_modified_utc
    from {{ source('lamp', 'lamp_index') }}
)

select
    loaded.service_date,
    loaded.loaded_at,
    index_files.last_modified_utc
from loaded
inner join index_files on loaded.service_date = index_files.service_date
where index_files.last_modified_utc > loaded.loaded_at
