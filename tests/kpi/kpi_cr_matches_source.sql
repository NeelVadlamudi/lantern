-- Commuter Rail daily figures equal the MBTA reliability file: per route and service date, on-time,
-- counted and cancelled trips in mart_cr_daily equal the staged file rows summed (peak and off-peak).
-- Returns the route-days that disagree or are missing on either side.

with source_days as (
    select
        source_route_id as route_id,
        service_date,
        sum(on_time_trips) as on_time_trips,
        sum(counted_trips) as counted_trips,
        sum(cancelled_trips) as cancelled_trips
    from {{ ref('stg_mbta__cr_reliability') }}
    group by source_route_id, service_date
)

select
    coalesce(daily.route_id, source_days.route_id) as route_id,
    coalesce(daily.service_date, source_days.service_date) as service_date
from {{ ref('mart_cr_daily') }} as daily
full outer join source_days
    on daily.route_id = source_days.route_id and daily.service_date = source_days.service_date
where
    daily.on_time_trips is distinct from source_days.on_time_trips
    or daily.counted_trips is distinct from source_days.counted_trips
    or daily.cancelled_trips is distinct from source_days.cancelled_trips
