-- Late-arriving data: LAMP sometimes republishes a service date's file after it was loaded.
-- lamp_files_to_load() re-reads such dates on the next incremental run; this test fails when a
-- loaded date's file in the index is newer than the time it was loaded, i.e. a republished file
-- was not picked up.
-- A republished file with no rows is not a miss: MBTA has replaced days with empty files, and
-- lamp_files_to_load() keeps the rows already loaded rather than blanking the day. Those file
-- versions are recorded in lamp_file_reads with num_rows = 0 and left out here.
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
left join {{ lamp_empty_file_versions() }} as empty_files
    on
        index_files.service_date = empty_files.service_date
        and index_files.last_modified_utc = empty_files.last_modified_utc
where
    index_files.last_modified_utc > loaded.loaded_at
    and empty_files.service_date is null
