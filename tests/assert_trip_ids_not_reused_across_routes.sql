{{ config(severity='warn') }}
-- LAMP documents one row per trip-stop per service date, but some trip ids show up on two
-- routes or two vehicles at the same stop on the same day. The fact grain includes route and
-- vehicle so these rows are kept; this test counts them.
select
    service_date,
    trip_id,
    stop_id,
    count(*) as n_rows
from {{ ref('stg_lamp__subway_trip_stops') }}
group by service_date, trip_id, stop_id
having count(*) > 1
