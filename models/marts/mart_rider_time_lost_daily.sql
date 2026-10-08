-- Grain: one row per service date. System-wide estimated rider time lost beyond the schedule,
-- in exact seconds: the sum over stations, lines and service periods of
-- mart_station_rider_time_lost. An estimate (gated entries weight, first-segment ride time;
-- see that model). Dates without a rider weight for their day type (a holiday when the rider
-- basis window has no holiday) have has_rider_data = false and null rider totals.

with cells as (

    select * from {{ ref('mart_station_rider_time_lost') }}

),

dates as (

    select
        date_key,
        date_day,
        day_type,
        is_holiday,
        holiday_name,
        week_start_date
    from {{ ref('dim_dates') }}

),

daily as (

    select
        date_key,
        count(*) as station_cells,
        count(*) filter (where has_rider_data) as station_cells_with_riders,
        sum(gated_entries) as gated_entries,
        sum(rider_wait_seconds_lost) as rider_wait_seconds_lost,
        sum(rider_ride_seconds_lost) as rider_ride_seconds_lost,
        sum(rider_seconds_lost) as rider_seconds_lost
    from cells
    group by date_key

)

select
    cast(dates.date_day as date) as service_date,
    cast(daily.date_key as integer) as date_key,
    cast(dates.day_type as varchar) as day_type,
    cast(dates.is_holiday as boolean) as is_holiday,
    cast(dates.holiday_name as varchar) as holiday_name,
    cast(dates.week_start_date as date) as week_start_date,
    cast(daily.station_cells as bigint) as station_cells,
    cast(daily.station_cells_with_riders as bigint) as station_cells_with_riders,
    cast(daily.station_cells_with_riders > 0 as boolean) as has_rider_data,
    cast(daily.gated_entries as double) as gated_entries,
    cast(daily.rider_wait_seconds_lost as double) as rider_wait_seconds_lost,
    cast(daily.rider_ride_seconds_lost as double) as rider_ride_seconds_lost,
    cast(daily.rider_seconds_lost as double) as rider_seconds_lost,
    cast(daily.rider_seconds_lost / nullif(daily.gated_entries, 0) as double) as seconds_lost_per_entry
from daily
inner join dates on daily.date_key = dates.date_key
