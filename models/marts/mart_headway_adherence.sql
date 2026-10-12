-- Grain: one row per line scope ('system' or a subway route id), service date and service hour.
-- Headway adherence with the SFMTA rules as published by Swiftly
-- (https://www.goswift.ly/blog/how-well-is-america-sticking-to-its-promised-headways):
--   bunched  the departure came less than var('bunched_max_seconds') (120 s, 2 min) after the
--            previous train at that stop
--   gapped   the gap was more than the scheduled gap plus var('gapped_extra_seconds') (300 s, 5 min)
-- Counted over departures with a headway comparison (actual and scheduled trunk headway both
-- known and above zero, fct_trip_stop_events.has_headway_comparison). These are separate from the
-- ratio-based is_bunched / is_long_gap flags used elsewhere on the board.

with events as (

    select
        route_id,
        service_date,
        date_key,
        {{ service_hour('event_local_at', 'service_date') }} as service_hour,
        headway_seconds < {{ var('bunched_max_seconds') }} as is_sfmta_bunched,
        headway_seconds > scheduled_headway_seconds + {{ var('gapped_extra_seconds') }} as is_sfmta_gapped
    from {{ ref('fct_trip_stop_events') }}
    where has_headway_comparison

),

scoped as (

    select
        route_id as scope_id,
        service_date,
        date_key,
        service_hour,
        is_sfmta_bunched,
        is_sfmta_gapped
    from events

    union all

    select
        'system' as scope_id,
        service_date,
        date_key,
        service_hour,
        is_sfmta_bunched,
        is_sfmta_gapped
    from events

)

select
    cast(scoped.scope_id as varchar) as scope_id,
    cast(scoped.service_date as date) as service_date,
    cast(scoped.date_key as integer) as date_key,
    cast(dates.day_type as varchar) as day_type,
    cast(scoped.service_hour as integer) as service_hour,
    cast(count(*) as bigint) as departures_compared,
    cast(count(*) filter (where scoped.is_sfmta_bunched) as bigint) as bunched_departures,
    cast(count(*) filter (where scoped.is_sfmta_gapped) as bigint) as gapped_departures,
    cast(count(*) filter (where scoped.is_sfmta_bunched) / count(*) as double) as bunched_share,
    cast(count(*) filter (where scoped.is_sfmta_gapped) / count(*) as double) as gapped_share
from scoped
inner join {{ ref('dim_dates') }} as dates on scoped.date_key = dates.date_key
group by scoped.scope_id, scoped.service_date, scoped.date_key, dates.day_type, scoped.service_hour
