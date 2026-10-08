-- Rider time lost adds up across grains (tolerance 1e-6 relative, floating-point sums):
--   daily = sum of station cells; weekly = sum of daily;
--   in-vehicle part of the station cells = sum of segment rider-weighted loss, per date.
with station_days as (
    select
        service_date,
        sum(rider_seconds_lost) as station_total,
        sum(rider_ride_seconds_lost) filter (where has_rider_data) as station_ride
    from {{ ref('mart_station_rider_time_lost') }}
    group by service_date
),

segment_days as (
    select
        service_date,
        sum(rider_seconds_lost) as segment_ride
    from {{ ref('mart_segment_daily') }}
    group by service_date
),

daily_check as (
    select
        'daily vs station cells' as check_name,
        cast(daily.service_date as varchar) as grain,
        daily.rider_seconds_lost as expected,
        station_days.station_total as actual
    from {{ ref('mart_rider_time_lost_daily') }} as daily
    inner join station_days on daily.service_date = station_days.service_date
    union all
    select
        'segment ride vs station ride' as check_name,
        cast(station_days.service_date as varchar) as grain,
        station_days.station_ride as expected,
        segment_days.segment_ride as actual
    from station_days
    inner join segment_days on station_days.service_date = segment_days.service_date
    union all
    select
        'weekly vs daily' as check_name,
        cast(weekly.week_start_date as varchar) as grain,
        weekly.rider_seconds_lost as expected,
        (
            select sum(daily.rider_seconds_lost)
            from {{ ref('mart_rider_time_lost_daily') }} as daily
            where daily.week_start_date = weekly.week_start_date
        ) as actual
    from {{ ref('mart_rider_time_lost_weekly') }} as weekly
)

select *
from daily_check
where
    (expected is null) != (actual is null)
    or abs(expected - actual) > 1e-6 * greatest(abs(expected), 1)
