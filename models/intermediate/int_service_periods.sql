-- Grain: one row per minute of the clock day (0-1439), labelled with its MBTA service period.
-- Period boundaries come from the MBTA Service Delivery Policy (Dec 2025), Table 1
-- (seed: service_periods). The policy defines them for weekdays; this project applies the same
-- clock bins to every day and keeps day type as a separate column downstream.

with minutes as (

    select cast(range as integer) as minute_of_day
    from range(0, 1440)

),

periods as (

    select * from {{ ref('service_periods') }}

)

select
    minutes.minute_of_day,
    periods.service_period_id,
    periods.service_period_name,
    periods.sort_order as service_period_sort_order
from minutes
inner join periods
    on minutes.minute_of_day between periods.start_minute and periods.end_minute
