-- depends_on: {{ ref('stg_lamp__subway_trip_stops') }}
{# Incremental runs replace whole service dates: a republished LAMP day can drop events,
   and a merge on the row key would keep those stale rows. #}
{{
    config(
        materialized='incremental',
        unique_key='service_date',
        incremental_strategy='delete+insert',
        on_schema_change='fail'
    )
}}

-- Grain: one row per service date, trip, route, vehicle and stop (a train arriving at a stop).
-- Incremental on service_date. Each run reprocesses the last var('incremental_lookback_days')
-- loaded service dates, because LAMP republishes recent files after late data arrives, plus any
-- older date staging has loaded or re-read since the fact last processed it.
--
-- Matched and added trips: is_matched_trip = the trip id is a trip in the GTFS schedule
-- published for the service date (int_scheduled_subway_trips). LAMP also records trips that
-- match no scheduled trip (ids starting 'ADDED-', is_added_trip): extra or re-assigned trains,
-- and pieces of a train's run recorded a second time under another id.
-- Double counts removed: the same train set (vehicle_label) recorded at the same station in the
-- same direction within var('duplicate_event_seconds') (60 s) under two trip ids is one stop
-- event, not two. The event of the higher-priority trip is kept: a matched trip first, then a
-- trip that is not 'ADDED-', then the trip with more stop events, then the lower trip key.
-- The other event is dropped; duplicate_events_dropped on the kept event counts them.
-- recorded_stop_position, previous_recorded_event_key and previous_recorded_station_id give the
-- event's place in its trip as LAMP recorded it, before any duplicate is dropped. int_train_runs
-- uses them so each run is the stretch LAMP timed, even when the stop before it was dropped.

with recursive source_events as (

    select * from {{ ref('int_trip_stops__performance') }}

    {% if is_incremental() %}
        where
            service_date >= (
                select max(this_fct.service_date) - {{ var('incremental_lookback_days') }}
                from {{ this }} as this_fct
            )
            -- older dates staging (re)loaded since the fact last saw them: a day MBTA published
            -- late, or a republished file read after the lookback
            or service_date in (
                select staged.service_date
                from {{ ref('stg_lamp__subway_trip_stops') }} as staged
                left join (
                    select service_date, max(loaded_at) as loaded_at from {{ this }} group by service_date
                ) as in_fact on staged.service_date = in_fact.service_date
                group by staged.service_date, in_fact.loaded_at
                having in_fact.loaded_at is null or max(staged._loaded_at) > in_fact.loaded_at
            )
    {% endif %}

),

scheduled as (

    select distinct
        service_date,
        trip_id
    from {{ ref('int_scheduled_subway_trips') }}

),

ranked as (

    select
        source_events.*,
        {{ dbt_utils.generate_surrogate_key([
            'source_events.service_date', 'source_events.trip_id', 'source_events.route_id',
            'source_events.vehicle_label'
        ]) }} as event_trip_key,
        scheduled.trip_id is not null as is_matched_trip,
        count(*) over (
            partition by
                source_events.service_date, source_events.trip_id, source_events.route_id,
                source_events.vehicle_label
        ) as trip_event_count,
        row_number() over (
            partition by
                source_events.service_date, source_events.trip_id, source_events.route_id,
                source_events.vehicle_label
            order by source_events.stop_sequence, source_events.event_local_at, source_events.trip_stop_event_key
        ) as recorded_stop_position,
        lag(source_events.trip_stop_event_key) over (
            partition by
                source_events.service_date, source_events.trip_id, source_events.route_id,
                source_events.vehicle_label
            order by source_events.stop_sequence, source_events.event_local_at, source_events.trip_stop_event_key
        ) as previous_recorded_event_key,
        lag(source_events.station_id) over (
            partition by
                source_events.service_date, source_events.trip_id, source_events.route_id,
                source_events.vehicle_label
            order by source_events.stop_sequence, source_events.event_local_at, source_events.trip_stop_event_key
        ) as previous_recorded_station_id
    from source_events
    left join scheduled
        on
            source_events.service_date = scheduled.service_date
            and source_events.trip_id = scheduled.trip_id

),

prioritised as (

    select
        *,
        -- higher sorts first: matched, not added, more events, then the lower trip key
        (case when is_matched_trip then 1 else 0 end) * 4 + (case when is_added_trip then 0 else 1 end) * 2
            as trip_class
    from ranked

),

duplicates as (

    -- one kept partner per dropped event: the highest-priority candidate, ties broken by the
    -- lower trip key and then the lower event key, so the pick never depends on row order
    select
        dropped.trip_stop_event_key as dropped_event_key,
        kept.trip_stop_event_key as kept_event_key
    from prioritised as dropped
    inner join prioritised as kept
        on
            dropped.service_date = kept.service_date
            and dropped.vehicle_label = kept.vehicle_label
            and dropped.station_id = kept.station_id
            and dropped.direction_id = kept.direction_id
            and dropped.event_trip_key <> kept.event_trip_key
            and abs(epoch(dropped.event_local_at) - epoch(kept.event_local_at)) <= {{ var('duplicate_event_seconds') }}
            and (
                dropped.trip_class < kept.trip_class
                or (dropped.trip_class = kept.trip_class and dropped.trip_event_count < kept.trip_event_count)
                or (
                    dropped.trip_class = kept.trip_class
                    and dropped.trip_event_count = kept.trip_event_count
                    and dropped.event_trip_key > kept.event_trip_key
                )
            )
    qualify row_number() over (
            partition by dropped.trip_stop_event_key
            order by
                kept.trip_class desc,
                kept.trip_event_count desc,
                kept.event_trip_key asc,
                kept.trip_stop_event_key asc
        ) = 1

),

-- the partner of a dropped event can itself be a duplicate of a third, higher-priority trip;
-- follow the chain (priority only rises, so it ends) to the event that is kept
duplicate_chain as (

    select
        dropped_event_key,
        kept_event_key,
        1 as chain_depth
    from duplicates

    union all

    select
        duplicate_chain.dropped_event_key,
        duplicates.kept_event_key,
        duplicate_chain.chain_depth + 1 as chain_depth
    from duplicate_chain
    inner join duplicates on duplicate_chain.kept_event_key = duplicates.dropped_event_key

),

dropped_per_kept as (

    select
        kept_event_key,
        count(*) as duplicate_events_dropped
    from (
        select
            dropped_event_key,
            arg_max(kept_event_key, chain_depth) as kept_event_key
        from duplicate_chain
        group by dropped_event_key
    ) as resolved
    group by kept_event_key

),

events as (

    select
        prioritised.*,
        coalesce(dropped_per_kept.duplicate_events_dropped, 0) as duplicate_events_dropped
    from prioritised
    left join dropped_per_kept on prioritised.trip_stop_event_key = dropped_per_kept.kept_event_key
    where prioritised.trip_stop_event_key not in (select duplicates.dropped_event_key from duplicates)

)

select
    cast(events.trip_stop_event_key as varchar) as trip_stop_event_key,
    {{ dbt_utils.generate_surrogate_key([
        'events.service_date', 'events.trip_id', 'events.route_id', 'events.vehicle_label'
    ]) }} as trip_key,
    cast(strftime(events.service_date, '%Y%m%d') as integer) as date_key,
    cast(events.service_date as date) as service_date,
    cast(events.route_id as varchar) as route_id,
    cast(events.branch_route_id as varchar) as branch_route_id,
    cast(events.line_id as varchar) as line_id,
    cast(events.station_id as varchar) as station_id,
    cast(events.stop_id as varchar) as stop_id,
    cast(events.service_period_id as varchar) as service_period_id,
    cast(events.direction_id as integer) as direction_id,
    cast(events.direction as varchar) as direction_name,
    cast(events.trip_id as varchar) as trip_id,
    cast(events.vehicle_label as varchar) as vehicle_label,
    cast(events.stop_sequence as integer) as stop_sequence,
    cast(events.is_added_trip as boolean) as is_added_trip,
    cast(events.is_matched_trip as boolean) as is_matched_trip,
    cast(events.duplicate_events_dropped as bigint) as duplicate_events_dropped,
    cast(events.recorded_stop_position as bigint) as recorded_stop_position,
    cast(events.previous_recorded_event_key as varchar) as previous_recorded_event_key,
    cast(events.previous_recorded_station_id as varchar) as previous_recorded_station_id,
    cast(events.event_local_at as timestamp) as event_local_at,
    cast(events.travel_time_seconds as bigint) as travel_time_seconds,
    cast(events.scheduled_travel_seconds as bigint) as scheduled_travel_seconds,
    cast(events.actual_run_seconds as bigint) as actual_run_seconds,
    cast(events.scheduled_run_seconds as bigint) as scheduled_run_seconds,
    cast(events.excess_travel_seconds as bigint) as excess_travel_seconds,
    cast(events.dwell_time_seconds as bigint) as dwell_time_seconds,
    cast(events.headway_trunk_seconds as bigint) as headway_seconds,
    cast(events.scheduled_headway_trunk_seconds as bigint) as scheduled_headway_seconds,
    cast(events.headway_ratio as double) as headway_ratio,
    cast(events.has_travel_comparison as boolean) as has_travel_comparison,
    cast(events.has_headway_comparison as boolean) as has_headway_comparison,
    cast(events.is_travel_outlier as boolean) as is_travel_outlier,
    cast(events.is_long_gap as boolean) as is_long_gap,
    cast(events.is_bunched as boolean) as is_bunched,
    cast(events.has_headway_comparison and not events.is_long_gap and not events.is_bunched as boolean)
        as is_headway_adherent,
    cast(events._loaded_at as timestamp) as loaded_at
from events
