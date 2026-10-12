-- Grain: one row per scope and calendar month. scope_id 'commuter_rail' = the 13 current CR-
-- routes together; otherwise a route id (CR-Middleborough and CapeFlyer included as their own
-- scopes, never in 'commuter_rail'). Exact sums from mart_cr_daily:
--   on_time_share = on_time_trips / counted_trips, cancelled_share = cancelled_trips / counted_trips.
-- is_complete_reliability_month / is_complete_boardings_month: the file covers every calendar day
-- of the month (the month lies inside the file's first and last service date). Boardings are the
-- MBTA's estimate; boardings_days counts the days with a value.

with daily as (

    select * from {{ ref('mart_cr_daily') }}

),

scoped as (

    select
        route_id as scope_id,
        *
    from daily

    union all

    select
        'commuter_rail' as scope_id,
        *
    from daily
    where is_current_route

),

coverage as (

    select
        (select min(service_date) from {{ ref('stg_mbta__cr_reliability') }}) as reliability_first_date,
        (select max(service_date) from {{ ref('stg_mbta__cr_reliability') }}) as reliability_last_date,
        (select min(service_date) from {{ ref('stg_mbta__cr_boardings') }}) as boardings_first_date,
        (select max(service_date) from {{ ref('stg_mbta__cr_boardings') }}) as boardings_last_date

),

monthly as (

    select
        scope_id,
        cast(date_trunc('month', service_date) as date) as month_start_date,
        count(distinct service_date) as reliability_days,
        sum(peak_on_time_trips) as peak_on_time_trips,
        sum(peak_counted_trips) as peak_counted_trips,
        sum(off_peak_on_time_trips) as off_peak_on_time_trips,
        sum(off_peak_counted_trips) as off_peak_counted_trips,
        sum(on_time_trips) as on_time_trips,
        sum(counted_trips) as counted_trips,
        sum(cancelled_trips) as cancelled_trips,
        count(distinct service_date) filter (where estimated_boardings is not null) as boardings_days,
        sum(estimated_boardings) as estimated_boardings_sum
    from scoped
    group by scope_id, date_trunc('month', service_date)

)

select
    {{ dbt_utils.generate_surrogate_key(['monthly.scope_id', 'monthly.month_start_date']) }} as cr_scope_month_key,
    cast(monthly.scope_id as varchar) as scope_id,
    cast(monthly.month_start_date as date) as month_start_date,
    cast(last_day(monthly.month_start_date) as date) as month_end_date,
    cast(monthly.reliability_days as bigint) as reliability_days,
    cast(monthly.peak_on_time_trips as bigint) as peak_on_time_trips,
    cast(monthly.peak_counted_trips as bigint) as peak_counted_trips,
    cast(monthly.off_peak_on_time_trips as bigint) as off_peak_on_time_trips,
    cast(monthly.off_peak_counted_trips as bigint) as off_peak_counted_trips,
    cast(monthly.on_time_trips as bigint) as on_time_trips,
    cast(monthly.counted_trips as bigint) as counted_trips,
    cast(monthly.cancelled_trips as bigint) as cancelled_trips,
    cast(monthly.on_time_trips / nullif(monthly.counted_trips, 0) as double) as on_time_share,
    cast(monthly.peak_on_time_trips / nullif(monthly.peak_counted_trips, 0) as double) as peak_on_time_share,
    cast(monthly.off_peak_on_time_trips / nullif(monthly.off_peak_counted_trips, 0) as double)
        as off_peak_on_time_share,
    cast(monthly.cancelled_trips / nullif(monthly.counted_trips, 0) as double) as cancelled_share,
    cast(monthly.boardings_days as bigint) as boardings_days,
    cast(monthly.estimated_boardings_sum as double) as estimated_boardings_sum,
    cast(monthly.estimated_boardings_sum / nullif(monthly.boardings_days, 0) as double)
        as avg_daily_estimated_boardings,
    cast(
        monthly.month_start_date >= coverage.reliability_first_date
        and last_day(monthly.month_start_date) <= coverage.reliability_last_date as boolean
    ) as is_complete_reliability_month,
    cast(
        monthly.month_start_date >= coverage.boardings_first_date
        and last_day(monthly.month_start_date) <= coverage.boardings_last_date as boolean
    ) as is_complete_boardings_month
from monthly
cross join coverage
