-- Rider time lost and its inputs add up across grains (tolerance 1e-6 relative, floating-point
-- sums):
--   daily = sum of station cells (without and with the gaps over 1 hour); weekly = sum of daily;
--   the excess ride sums of the station cells = the net excess of the segments starting there,
--   per date (mart_segment_daily);
--   the gaps over 1 hour in the daily mart = the rows of fct_suspension_gaps, count and seconds,
--   and suspension = waited + non-wait.
with station_days as (
    select
        service_date,
        sum(rider_seconds_lost) as station_total,
        sum(rider_seconds_lost_with_gaps) as station_total_with_gaps,
        sum(excess_ride_seconds_sum) as station_ride_excess
    from {{ ref('mart_station_rider_time_lost') }}
    group by service_date
),

segment_days as (
    select
        service_date,
        sum(net_excess_seconds_sum) as segment_net_excess
    from {{ ref('mart_segment_daily') }}
    group by service_date
),

gap_days as (
    select
        service_date,
        count(*) as gaps,
        sum(gap_seconds) as gap_seconds
    from {{ ref('fct_suspension_gaps') }}
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
        'daily vs station cells, with gaps' as check_name,
        cast(daily.service_date as varchar) as grain,
        daily.rider_seconds_lost_with_gaps as expected,
        station_days.station_total_with_gaps as actual
    from {{ ref('mart_rider_time_lost_daily') }} as daily
    inner join station_days on daily.service_date = station_days.service_date
    union all
    select
        'segment net excess vs station ride excess' as check_name,
        cast(station_days.service_date as varchar) as grain,
        station_days.station_ride_excess as expected,
        segment_days.segment_net_excess as actual
    from station_days
    inner join segment_days on station_days.service_date = segment_days.service_date
    union all
    select
        'daily gap count vs fct_suspension_gaps' as check_name,
        cast(daily.service_date as varchar) as grain,
        daily.suspension_gap_count as expected,
        coalesce(gap_days.gaps, 0) as actual
    from {{ ref('mart_rider_time_lost_daily') }} as daily
    left join gap_days on daily.service_date = gap_days.service_date
    union all
    select
        'daily gap seconds vs fct_suspension_gaps' as check_name,
        cast(daily.service_date as varchar) as grain,
        daily.suspension_gap_seconds as expected,
        coalesce(gap_days.gap_seconds, 0) as actual
    from {{ ref('mart_rider_time_lost_daily') }} as daily
    left join gap_days on daily.service_date = gap_days.service_date
    union all
    select
        'suspension = waited + non-wait' as check_name,
        cast(daily.service_date as varchar) as grain,
        daily.suspension_gap_seconds as expected,
        daily.waited_gap_seconds + daily.non_wait_gap_seconds as actual
    from {{ ref('mart_rider_time_lost_daily') }} as daily
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
