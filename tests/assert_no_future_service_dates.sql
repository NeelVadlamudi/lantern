-- No loaded service date may be later than today in Boston. A future date means a bad file or
-- index row (or a wrong lamp_end_date) and would stretch dim_dates past the real data.
select distinct service_date
from {{ ref('stg_lamp__subway_trip_stops') }}
where service_date > cast(now() at time zone 'America/New_York' as date)
