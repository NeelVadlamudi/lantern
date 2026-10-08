-- Grain: one row per week (weeks start on Monday). Weekly trend of estimated rider time lost
-- beyond the schedule, from mart_rider_time_lost_daily. Averages are per service date with a
-- rider weight, so a short first or last week is comparable to a full one; is_complete_week
-- says whether all 7 dates are loaded.

with daily as (

    select * from {{ ref('mart_rider_time_lost_daily') }}

)

select
    cast(week_start_date as date) as week_start_date,
    cast(week_start_date + 6 as date) as week_end_date,
    cast(min(service_date) as date) as first_service_date,
    cast(max(service_date) as date) as last_service_date,
    cast(count(*) as integer) as service_dates,
    cast(count(*) filter (where has_rider_data) as integer) as dates_with_rider_data,
    cast(count(*) filter (where has_rider_data and day_type = 'weekday') as integer) as weekdays_with_rider_data,
    cast(count(*) = 7 as boolean) as is_complete_week,
    cast(sum(rider_seconds_lost) as double) as rider_seconds_lost,
    cast(sum(rider_wait_seconds_lost) as double) as rider_wait_seconds_lost,
    cast(sum(rider_ride_seconds_lost) as double) as rider_ride_seconds_lost,
    cast(avg(rider_seconds_lost) filter (where has_rider_data) as double) as avg_daily_rider_seconds_lost,
    cast(avg(rider_seconds_lost) filter (where has_rider_data and day_type = 'weekday') as double)
        as avg_weekday_rider_seconds_lost,
    cast(sum(rider_seconds_lost) / nullif(sum(gated_entries), 0) as double) as seconds_lost_per_entry
from daily
group by week_start_date
