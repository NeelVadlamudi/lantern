-- duplicate_events_dropped is assigned the same way on every build: each dropped event goes to
-- the highest-priority partner event (matched, not added, more stop events), ties broken by the
-- lower trip key and then the lower event key. Recomputed here from the raw stop events with an
-- explicit ordering and compared, event by event, with fct_trip_stop_events. Chains (a partner
-- that is itself dropped) are followed to the event that is kept, as in the model.
with recursive source_events as (
    select * from {{ ref('int_trip_stops__performance') }}
),

scheduled as (
    select distinct service_date, trip_id from {{ ref('int_scheduled_subway_trips') }}
),

ranked as (
    select
        source_events.trip_stop_event_key,
        source_events.service_date,
        source_events.vehicle_label,
        source_events.station_id,
        source_events.direction_id,
        source_events.event_local_at,
        {{ dbt_utils.generate_surrogate_key([
            'source_events.service_date', 'source_events.trip_id', 'source_events.route_id',
            'source_events.vehicle_label'
        ]) }} as event_trip_key,
        (case when scheduled.trip_id is not null then 1 else 0 end) * 4
        + (case when source_events.is_added_trip then 0 else 1 end) * 2 as trip_class,
        count(*) over (
            partition by
                source_events.service_date, source_events.trip_id, source_events.route_id,
                source_events.vehicle_label
        ) as trip_event_count
    from source_events
    left join scheduled
        on source_events.service_date = scheduled.service_date and source_events.trip_id = scheduled.trip_id
),

candidates as (
    select
        dropped.trip_stop_event_key as dropped_event_key,
        kept.trip_stop_event_key as kept_event_key,
        kept.trip_class,
        kept.trip_event_count,
        kept.event_trip_key
    from ranked as dropped
    inner join ranked as kept
        on
            dropped.service_date = kept.service_date
            and dropped.vehicle_label = kept.vehicle_label
            and dropped.station_id = kept.station_id
            and dropped.direction_id = kept.direction_id
            and dropped.event_trip_key <> kept.event_trip_key
            and abs(epoch(dropped.event_local_at) - epoch(kept.event_local_at)) <= {{ var('duplicate_event_seconds') }}
            and (dropped.trip_class, dropped.trip_event_count, kept.event_trip_key)
            < (kept.trip_class, kept.trip_event_count, dropped.event_trip_key)
),

best as (
    select
        dropped_event_key,
        arg_min(kept_event_key, (-trip_class, -trip_event_count, event_trip_key, kept_event_key)) as kept_event_key
    from candidates
    group by dropped_event_key
),

chain as (
    select dropped_event_key, kept_event_key, 1 as depth from best
    union all
    select chain.dropped_event_key, best.kept_event_key, chain.depth + 1
    from chain inner join best on chain.kept_event_key = best.dropped_event_key
),

expected as (
    select kept_event_key, count(*) as dropped_events
    from (
        select dropped_event_key, arg_max(kept_event_key, depth) as kept_event_key
        from chain group by dropped_event_key
    ) as resolved
    group by kept_event_key
)

select
    events.trip_stop_event_key,
    events.duplicate_events_dropped,
    coalesce(expected.dropped_events, 0) as expected_dropped
from {{ ref('fct_trip_stop_events') }} as events
left join expected on events.trip_stop_event_key = expected.kept_event_key
where events.duplicate_events_dropped <> coalesce(expected.dropped_events, 0)
