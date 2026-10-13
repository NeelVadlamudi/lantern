-- Grain: one row per scheduled subway trip and service date in the loaded window (dim_dates).
-- A trip is scheduled on a date when, in the GTFS archive rows valid on that date, its service_id
-- runs that weekday between the calendar start and end dates and is not removed on the date
-- (calendar_dates exception_type 2), or is added on the date (exception_type 1). This is the
-- schedule as published for that date, the same one LAMP compares against.
-- service_id is kept: the MBTA publishes planned diversions as their own services (ids starting
-- 'DIV'), which mart_service_changes reads.

with dates as (

    select
        date_day as service_date,
        isodow(date_day) as iso_dow
    from {{ ref('dim_dates') }}

),

calendar as (

    select * from {{ ref('stg_gtfs__calendar') }}

),

exceptions as (

    select * from {{ ref('stg_gtfs__calendar_dates') }}

),

trips as (

    select * from {{ ref('stg_gtfs__subway_trips') }}

),

weekly as (

    select distinct
        dates.service_date,
        calendar.service_id
    from dates
    inner join calendar
        on
            dates.service_date between calendar.valid_from_date and calendar.valid_to_date
            and dates.service_date between calendar.start_date and calendar.end_date
            and case dates.iso_dow
                when 1 then calendar.runs_monday
                when 2 then calendar.runs_tuesday
                when 3 then calendar.runs_wednesday
                when 4 then calendar.runs_thursday
                when 5 then calendar.runs_friday
                when 6 then calendar.runs_saturday
                else calendar.runs_sunday
            end

),

day_exceptions as (

    select distinct
        exceptions.service_date,
        exceptions.service_id,
        exceptions.exception_type
    from exceptions
    inner join dates
        on
            exceptions.service_date = dates.service_date
            and dates.service_date between exceptions.valid_from_date and exceptions.valid_to_date

),

active_services as (

    select
        weekly.service_date,
        weekly.service_id
    from weekly
    left join day_exceptions as removed
        on
            weekly.service_date = removed.service_date
            and weekly.service_id = removed.service_id
            and removed.exception_type = 2
    where removed.service_id is null

    union

    select
        service_date,
        service_id
    from day_exceptions
    where exception_type = 1

)

select distinct
    cast(active_services.service_date as date) as service_date,
    cast(trips.route_id as varchar) as route_id,
    cast(trips.trip_id as varchar) as trip_id,
    cast(trips.direction_id as integer) as direction_id,
    cast(trips.service_id as varchar) as service_id
from active_services
inner join trips
    on
        active_services.service_id = trips.service_id
        and active_services.service_date between trips.valid_from_date and trips.valid_to_date
