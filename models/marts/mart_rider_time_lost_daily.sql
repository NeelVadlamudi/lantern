-- Grain: one row per service date. System-wide estimated rider time lost beyond the schedule,
-- in exact seconds: the sum over stations, lines and service periods of
-- mart_station_rider_time_lost. An estimate (gated entries weight, first-segment ride time;
-- see that model). Dates without a rider weight for their day type (a holiday when the rider
-- basis window has no holiday) have has_rider_data = false and null rider totals.
-- Wait is given without and with the gaps over 1 hour (*_with_gaps; see
-- mart_station_rider_time_lost and fct_suspension_gaps). The gaps themselves are counted in
-- suspension_gap_* (all), waited_gap_* (kept as passenger waits) and non_wait_gap_* (shown by
-- the recorded data not to be waits); suspension = waited + non-wait.
-- Gate entries reconcile to the rider weights: gated_entries is the weight of the cells with
-- recorded trains that date; gated_entries_no_trains is the weight of the station, line and
-- period cells of the date's day type that had no recorded train (counted in cells_no_trains),
-- and gated_entries_all_cells = gated_entries + gated_entries_no_trains, the sum of
-- int_station_period_riders for the day type. The no-train part adds nothing to rider time lost.

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

riders as (

    select
        station_id,
        line_id,
        day_type,
        service_period_id,
        cast(avg_daily_gated_entries as double) as avg_daily_gated_entries
    from {{ ref('int_station_period_riders') }}

),

cell_keys as (

    select distinct
        station_id,
        line_id,
        date_key,
        service_period_id
    from cells

),

no_train_cells as (

    select
        dates.date_key,
        count(*) as cells_no_trains,
        sum(riders.avg_daily_gated_entries) as gated_entries_no_trains
    from dates
    inner join riders on dates.day_type = riders.day_type
    left join cell_keys
        on
            riders.station_id = cell_keys.station_id
            and riders.line_id = cell_keys.line_id
            and dates.date_key = cell_keys.date_key
            and riders.service_period_id = cell_keys.service_period_id
    where cell_keys.station_id is null
    group by dates.date_key

),

daily as (

    select
        date_key,
        count(*) as station_cells,
        count(*) filter (where has_rider_data) as station_cells_with_riders,
        sum(gated_entries) as gated_entries,
        sum(rider_wait_seconds_lost) as rider_wait_seconds_lost,
        sum(rider_ride_seconds_lost) as rider_ride_seconds_lost,
        sum(rider_seconds_lost) as rider_seconds_lost,
        sum(rider_wait_seconds_lost_with_gaps) as rider_wait_seconds_lost_with_gaps,
        sum(rider_seconds_lost_with_gaps) as rider_seconds_lost_with_gaps,
        sum(suspension_gap_count) as suspension_gap_count,
        sum(suspension_gap_seconds) as suspension_gap_seconds,
        sum(waited_gap_count) as waited_gap_count,
        sum(waited_gap_seconds) as waited_gap_seconds,
        sum(non_wait_gap_count) as non_wait_gap_count,
        sum(non_wait_gap_seconds) as non_wait_gap_seconds
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
    cast(daily.rider_seconds_lost / nullif(daily.gated_entries, 0) as double) as seconds_lost_per_entry,
    cast(daily.rider_wait_seconds_lost_with_gaps as double) as rider_wait_seconds_lost_with_gaps,
    cast(daily.rider_seconds_lost_with_gaps as double) as rider_seconds_lost_with_gaps,
    cast(daily.rider_seconds_lost_with_gaps / nullif(daily.gated_entries, 0) as double)
        as seconds_lost_per_entry_with_gaps,
    cast(daily.suspension_gap_count as bigint) as suspension_gap_count,
    cast(daily.suspension_gap_seconds as double) as suspension_gap_seconds,
    cast(daily.waited_gap_count as bigint) as waited_gap_count,
    cast(daily.waited_gap_seconds as double) as waited_gap_seconds,
    cast(daily.non_wait_gap_count as bigint) as non_wait_gap_count,
    cast(daily.non_wait_gap_seconds as double) as non_wait_gap_seconds,
    cast(coalesce(no_train_cells.cells_no_trains, 0) as bigint) as cells_no_trains,
    cast(case
        when daily.station_cells_with_riders > 0 then coalesce(no_train_cells.gated_entries_no_trains, 0)
    end as double) as gated_entries_no_trains,
    cast(case
        when daily.station_cells_with_riders > 0
            then daily.gated_entries + coalesce(no_train_cells.gated_entries_no_trains, 0)
    end as double) as gated_entries_all_cells
from daily
inner join dates on daily.date_key = dates.date_key
left join no_train_cells on daily.date_key = no_train_cells.date_key
