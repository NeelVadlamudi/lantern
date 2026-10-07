-- Grain: one row per service date, station, line and 30-minute bin.

with source as (

    select * from {{ source('mbta_open_data', 'mbta_gated_station_entries') }}

)

select
    cast(strptime(left(service_date, 10), '%Y/%m/%d') as date) as service_date,
    -- "(07:30:00)" -> 450 minutes after midnight (start of the bin)
    cast(substr(time_period, 2, 2) as integer) * 60 + cast(substr(time_period, 5, 2) as integer)
        as bin_start_minute,
    nullif(stop_id, '') as station_id,
    station_name,
    route_or_line,
    cast(gated_entries as double) as gated_entries
from source
