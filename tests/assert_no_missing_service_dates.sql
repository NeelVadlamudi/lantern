-- The loaded LAMP window must have no gaps: every date between the first and last loaded
-- service date needs data. A gap means a failed or skipped load.
with loaded as (
    select distinct service_date from {{ ref('stg_lamp__subway_trip_stops') }}
)
select d.date_day as missing_service_date
from {{ ref('dim_dates') }} as d
left join loaded on d.date_day = loaded.service_date
where loaded.service_date is null
