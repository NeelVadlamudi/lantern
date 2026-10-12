-- Grain: one row per period and GTFS route. Share of measured train delay (positive excess:
-- sum of max(run - scheduled, 0) over compared runs, int_train_runs) by line, for the donut:
--   period_kind 'date'      one service date (service_date set)
--   period_kind 'weekday'   all weekdays in the window (service_date null)
--   period_kind 'all_days'  every service date in the window (service_date null)
-- share_of_positive_excess = the route's positive excess / all routes' positive excess for the
-- same period. Exact sums; net excess and run counts are carried for hover text.

with runs as (

    select
        runs.route_id,
        runs.service_date,
        runs.day_type,
        runs.positive_excess_seconds,
        runs.net_excess_seconds
    from {{ ref('int_train_runs') }} as runs
    where runs.is_compared

),

periods as (

    select
        'date' as period_kind,
        service_date,
        route_id,
        count(distinct service_date) as service_dates,
        count(*) as runs_compared,
        sum(positive_excess_seconds) as positive_excess_seconds,
        sum(net_excess_seconds) as net_excess_seconds
    from runs
    group by service_date, route_id

    union all

    select
        'weekday' as period_kind,
        null as service_date,
        route_id,
        (
            select count(distinct w.service_date) from runs as w
            where w.day_type = 'weekday'
        ) as service_dates,
        count(*) as runs_compared,
        sum(positive_excess_seconds) as positive_excess_seconds,
        sum(net_excess_seconds) as net_excess_seconds
    from runs
    where day_type = 'weekday'
    group by route_id

    union all

    select
        'all_days' as period_kind,
        null as service_date,
        route_id,
        (select count(distinct a.service_date) from runs as a) as service_dates,
        count(*) as runs_compared,
        sum(positive_excess_seconds) as positive_excess_seconds,
        sum(net_excess_seconds) as net_excess_seconds
    from runs
    group by route_id

)

select
    {{ dbt_utils.generate_surrogate_key(['period_kind', 'service_date', 'route_id']) }} as line_period_key,
    cast(period_kind as varchar) as period_kind,
    cast(service_date as date) as service_date,
    cast(route_id as varchar) as route_id,
    cast(service_dates as bigint) as service_dates,
    cast(runs_compared as bigint) as runs_compared,
    cast(positive_excess_seconds as double) as positive_excess_seconds,
    cast(net_excess_seconds as double) as net_excess_seconds,
    cast(positive_excess_seconds / service_dates as double) as avg_daily_positive_excess_seconds,
    cast(sum(positive_excess_seconds) over (partition by period_kind, service_date) as double)
        as system_positive_excess_seconds,
    cast(positive_excess_seconds / sum(positive_excess_seconds) over (partition by period_kind, service_date) as double)
        as share_of_positive_excess
from periods
