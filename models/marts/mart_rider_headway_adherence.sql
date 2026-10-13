-- Grain: one row per scope (a GTFS route id, 'Green' = the four branches combined, or
-- 'system'), day type and service period (MBTA Service Delivery Policy periods), over the
-- loaded window.
-- Rider-weighted headway adherence: the estimated share of riders whose wait for a train was no
-- longer than the allowed wait, after the MBTA's passenger wait time standard for frequent
-- service (Service Delivery Policy, Fall 2024: share of passengers waiting no longer than the
-- scheduled headway; on the Green Line trunk, 3 minutes or the scheduled headway, whichever is
-- larger).
-- For every departure with a headway comparison (fct_trip_stop_events, duplicates removed):
--   h = actual gap since the previous train (LAMP trunk headway), H = scheduled gap
--   T = greatest(H, var('green_trunk_min_allowance_seconds')) (180 s) at Green Line trunk
--       stations (stations on two or more Green branch patterns), H everywhere else
--   riders arriving at random during the gap: share waiting no longer than T = least(h, T) / h
--   riders in the gap = arrival rate r times h, so riders within the allowance = r * least(h, T)
-- Arrival rate r (riders per second) at a station, line, direction, day type and period:
--   average daily fare-gate entries for the station, line, day type and period
--   (int_station_period_riders, rider basis window) / period length in seconds / 2: entries are
--   split 50/50 between the two directions (the gates do not record direction).
--   Stations without fare gates (Green Line surface stops, most of Mattapan) get the same rate
--   at every such stop: the average rate of the gated stations of that line, day type and
--   period. Holidays use the Sunday rates. Transfers between lines inside stations are not
--   counted (gate entries only).
-- Line-days with a planned service change (mart_planned_change_line_days) are left out.
-- rider_weighted_share = sum(r * least(h, T)) / sum(r * h)
-- unweighted_share     = sum(least(h, T)) / sum(h) (the same with one rate everywhere)
-- departure_share      = share of departures with h <= T (no rider weighting)

with events as (

    select
        events.route_id,
        events.line_id,
        events.station_id,
        events.direction_id,
        events.service_date,
        events.service_period_id,
        dates.day_type,
        cast(events.headway_seconds as double) as headway_seconds,
        cast(events.scheduled_headway_seconds as double) as scheduled_headway_seconds
    from {{ ref('fct_trip_stop_events') }} as events
    inner join {{ ref('dim_dates') }} as dates on events.service_date = dates.date_day
    inner join {{ ref('mart_planned_change_line_days') }} as planned
        on events.route_id = planned.route_id and events.service_date = planned.service_date
    where
        events.has_headway_comparison
        and events.headway_seconds > 0
        and events.scheduled_headway_seconds > 0
        and not planned.is_planned_change

),

green_trunk as (

    select station_id
    from {{ ref('int_line_stop_sequence') }}
    where route_id like 'Green-%'
    group by station_id
    having count(distinct route_id) >= 2

),

period_seconds as (

    select
        service_period_id,
        count(*) * 60 as period_seconds
    from {{ ref('int_service_periods') }}
    group by service_period_id

),

gated as (

    select
        riders.station_id,
        riders.line_id,
        riders.day_type,
        riders.service_period_id,
        cast(riders.avg_daily_gated_entries as double) / period_seconds.period_seconds / 2 as rate_per_second
    from {{ ref('int_station_period_riders') }} as riders
    inner join period_seconds on riders.service_period_id = period_seconds.service_period_id

),

ungated_rate as (

    select
        line_id,
        day_type,
        service_period_id,
        avg(rate_per_second) as rate_per_second
    from gated
    group by line_id, day_type, service_period_id

),

weighted as (

    select
        events.*,
        events.station_id in (select green_trunk.station_id from green_trunk)
        and events.line_id = 'Green' as is_green_trunk,
        case
            when events.station_id in (select green_trunk.station_id from green_trunk) and events.line_id = 'Green'
                then greatest(events.scheduled_headway_seconds, {{ var('green_trunk_min_allowance_seconds') }})
            else events.scheduled_headway_seconds
        end as allowance_seconds,
        gated.rate_per_second is not null as is_gated,
        coalesce(gated.rate_per_second, ungated_rate.rate_per_second) as rate_per_second
    from events
    left join gated
        on
            events.station_id = gated.station_id
            and events.line_id = gated.line_id
            and case when events.day_type = 'holiday' then 'sunday' else events.day_type end = gated.day_type
            and events.service_period_id = gated.service_period_id
    left join ungated_rate
        on
            events.line_id = ungated_rate.line_id
            and case when events.day_type = 'holiday' then 'sunday' else events.day_type end = ungated_rate.day_type
            and events.service_period_id = ungated_rate.service_period_id

),

scoped as (

    select
        route_id as scope_id,
        *
    from weighted
    union all
    select
        'Green' as scope_id,
        *
    from weighted
    where route_id like 'Green-%'
    union all
    select
        'system' as scope_id,
        *
    from weighted

)

select
    {{ dbt_utils.generate_surrogate_key(['scope_id', 'day_type', 'service_period_id']) }} as scope_period_key,
    cast(scope_id as varchar) as scope_id,
    cast(day_type as varchar) as day_type,
    cast(service_period_id as varchar) as service_period_id,
    cast(count(distinct service_date) as bigint) as service_days,
    cast(count(*) as bigint) as departures,
    cast(count(*) filter (where is_gated) as bigint) as departures_at_gated_stations,
    cast(count(*) filter (where is_green_trunk) as bigint) as departures_at_green_trunk,
    cast(count(*) filter (where rate_per_second is not null) as bigint) as departures_weighted,
    cast(sum(rate_per_second * headway_seconds) as double) as est_riders,
    cast(sum(rate_per_second * least(headway_seconds, allowance_seconds)) as double) as est_riders_within_allowance,
    cast(
        sum(rate_per_second * least(headway_seconds, allowance_seconds))
        / nullif(sum(rate_per_second * headway_seconds), 0) as double
    ) as rider_weighted_share,
    cast(sum(least(headway_seconds, allowance_seconds)) / sum(headway_seconds) as double) as unweighted_share,
    cast(avg(case when headway_seconds <= allowance_seconds then 1 else 0 end) as double) as departure_share
from scoped
group by scope_id, day_type, service_period_id
