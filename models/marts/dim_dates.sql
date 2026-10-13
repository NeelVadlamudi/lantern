-- Grain: one row per calendar date in the reporting window: the last var('reporting_window_days')
-- (90) calendar dates ending on the latest loaded service date, or from the first loaded date
-- when less is loaded. The facts keep older loaded dates; marts and exports join to this table
-- (or filter on it) so the window rolls forward with each daily build and never grows.

with bounds as (

    select
        greatest(
            min(service_date),
            max(service_date) - {{ var('reporting_window_days') - 1 }}
        ) as first_date,
        max(service_date) as last_date
    from {{ ref('stg_lamp__subway_trip_stops') }}

),

spine as (

    select cast(unnest(generate_series(first_date, last_date, interval 1 day)) as date) as date_day
    from bounds

)

select
    cast(strftime(spine.date_day, '%Y%m%d') as integer) as date_key,
    spine.date_day,
    cast(dayname(spine.date_day) as varchar) as day_name,
    cast(isodow(spine.date_day) as integer) as iso_day_of_week,
    cast({{ day_type('spine.date_day') }} as varchar) as day_type,
    holidays.holiday_name is not null as is_holiday,
    cast(holidays.holiday_name as varchar) as holiday_name,
    cast(date_trunc('month', spine.date_day) as date) as month_start_date,
    cast(date_trunc('week', spine.date_day) as date) as week_start_date,
    {{ dst_extra_hours('spine.date_day') }} as dst_extra_hours
from spine
left join {{ ref('holidays') }} as holidays
    on spine.date_day = holidays.holiday_date
