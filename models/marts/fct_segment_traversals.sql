-- Grain: one row per train run over one track segment (dim_segments): the trip-stop event at
-- the segment's end station whose previous observed stop on the same trip was the segment's
-- start station. Only traversals compared to the schedule (has_travel_comparison: actual and
-- scheduled run time both positive, actual at most travel_outlier_seconds) are kept.
-- Stops are ordered by stop_sequence, then event time and key (some trips repeat a
-- stop_sequence, e.g. Mattapan and Union Square trips starting at either end).
-- Observed stop pairs that are not consecutive on a canonical pattern (a skipped or missing
-- stop) are left out; mart_data_coverage-style counts are in the model tests.

with events as (

    select
        *,
        lag(station_id) over (
            partition by trip_key order by stop_sequence, event_local_at, trip_stop_event_key
        ) as previous_station_id
    from {{ ref('fct_trip_stop_events') }}

),

segments as (

    select
        segment_id,
        line_id,
        direction_id,
        from_station_id,
        to_station_id
    from {{ ref('dim_segments') }}

),

dates as (

    select
        date_key,
        day_type
    from {{ ref('dim_dates') }}

)

select
    events.trip_stop_event_key as segment_traversal_key,
    segments.segment_id,
    cast(events.trip_key as varchar) as trip_key,
    cast(events.service_date as date) as service_date,
    cast(events.date_key as integer) as date_key,
    cast(dates.day_type as varchar) as day_type,
    cast(events.service_period_id as varchar) as service_period_id,
    cast(events.line_id as varchar) as line_id,
    cast(events.route_id as varchar) as route_id,
    cast(events.branch_route_id as varchar) as branch_route_id,
    cast(events.direction_id as integer) as direction_id,
    cast(segments.from_station_id as varchar) as from_station_id,
    cast(segments.to_station_id as varchar) as to_station_id,
    cast(events.actual_run_seconds as bigint) as actual_run_seconds,
    cast(events.scheduled_run_seconds as bigint) as scheduled_run_seconds,
    cast(events.excess_travel_seconds as bigint) as excess_travel_seconds
from events
inner join segments
    on
        events.line_id = segments.line_id
        and events.direction_id = segments.direction_id
        and events.previous_station_id = segments.from_station_id
        and events.station_id = segments.to_station_id
inner join dates on events.date_key = dates.date_key
where events.has_travel_comparison
