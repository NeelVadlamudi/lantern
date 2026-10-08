-- Grain: one row per train departure whose gap since the previous train on the line
-- (fct_trip_stop_events.headway_seconds, LAMP's trunk headway at that platform) is longer than
-- var('wait_max_headway_seconds') (1 hour). These are counted separately from ordinary waits
-- (suspension_gap_* columns in the rider time lost marts); none are dropped.
-- The recorded LAMP departures are used to check each gap:
--   departed_at       = when this train left the platform (LAMP move time at its next stop)
--   gap_start_at      = departed_at - gap_seconds (the previous departure LAMP counted)
--   gap_start_service_date = service date of the departure recorded at that platform exactly
--                       at gap_start_at (null when LAMP counted a departure that is not in the files)
--   recorded_departures_in_gap = departures recorded at the same platform (stop_id) strictly
--                       between gap_start_at and departed_at (LAMP's headway skipped them)
-- gap_kind:
--   'spans_service_day_boundary'  the gap starts at a departure recorded on an earlier service
--                                 date, so it runs through the overnight break. Not a passenger wait.
--   'departure_recorded_inside'   trains were recorded leaving the platform during the gap. The
--                                 wait is split at those recorded departures (see below).
--   'departure_not_recorded'      LAMP has no departure time for this train (its next stop is not
--                                 in the file), so the gap cannot be placed or checked. Kept as
--                                 one wait of gap_seconds.
--   'no_departure_recorded_inside' no train was recorded leaving that platform during the gap
--                                 (a suspension with shuttle buses, or a real gap). One wait.
-- recorded_gap_squared_sum = sum of the squared pieces of the gap between gap_start_at, each
-- recorded departure inside it and departed_at (the pieces add up to gap_seconds exactly; with
-- no departure inside it is gap_seconds squared). The rider marts use it for the expected wait,
-- so a gap with trains recorded inside it counts as the shorter waits riders actually had.
-- is_passenger_wait is false only for 'spans_service_day_boundary'; those gaps are counted in
-- non_wait_gap_* and left out of "wait with gaps".

with gaps as (

    select
        trip_stop_event_key,
        service_date,
        date_key,
        service_period_id,
        line_id,
        route_id,
        direction_id,
        station_id,
        stop_id,
        headway_seconds,
        scheduled_headway_seconds
    from {{ ref('fct_trip_stop_events') }}
    where has_headway_comparison and headway_seconds > {{ var('wait_max_headway_seconds') }}

),

departures as (

    select
        trip_stop_event_key,
        service_date,
        stop_id,
        {{ to_boston_time('lead(moved_at) over (
            partition by service_date, trip_id, route_id, vehicle_label order by stop_sequence, stopped_at
        )') }} as departed_at
    from {{ ref('stg_lamp__subway_trip_stops') }}

),

gap_stop_departures as (

    select *
    from departures
    where
        departed_at is not null
        and stop_id in (select gaps.stop_id from gaps)

),

placed as (

    select
        gaps.*,
        departures.departed_at,
        departures.departed_at - to_seconds(gaps.headway_seconds) as gap_start_at
    from gaps
    left join departures on gaps.trip_stop_event_key = departures.trip_stop_event_key

),

gap_start as (

    select
        placed.trip_stop_event_key,
        min(gap_stop_departures.service_date) as gap_start_service_date
    from placed
    inner join gap_stop_departures
        on
            placed.stop_id = gap_stop_departures.stop_id
            and placed.gap_start_at = gap_stop_departures.departed_at
    group by placed.trip_stop_event_key

),

piece_ends as (

    select
        placed.trip_stop_event_key,
        placed.gap_start_at,
        gap_stop_departures.departed_at as piece_end_at,
        true as is_inside
    from placed
    inner join gap_stop_departures
        on
            placed.stop_id = gap_stop_departures.stop_id
            and placed.gap_start_at < gap_stop_departures.departed_at
            and placed.departed_at > gap_stop_departures.departed_at

    union all

    select
        trip_stop_event_key,
        gap_start_at,
        departed_at as piece_end_at,
        false as is_inside
    from placed
    where departed_at is not null

),

pieces as (

    select
        trip_stop_event_key,
        is_inside,
        epoch(piece_end_at) - epoch(
            coalesce(lag(piece_end_at) over (partition by trip_stop_event_key order by piece_end_at), gap_start_at)
        ) as piece_seconds
    from piece_ends

),

split as (

    select
        trip_stop_event_key,
        count(*) filter (where is_inside) as recorded_departures_in_gap,
        sum(piece_seconds * piece_seconds) as recorded_gap_squared_sum,
        max(piece_seconds) as longest_recorded_piece_seconds
    from pieces
    group by trip_stop_event_key

),

classified as (

    select
        placed.*,
        gap_start.gap_start_service_date,
        coalesce(split.recorded_departures_in_gap, 0) as recorded_departures_in_gap,
        coalesce(split.recorded_gap_squared_sum, cast(placed.headway_seconds as double) * placed.headway_seconds)
            as recorded_gap_squared_sum,
        coalesce(split.longest_recorded_piece_seconds, placed.headway_seconds) as longest_recorded_piece_seconds,
        case
            when gap_start.gap_start_service_date < placed.service_date then 'spans_service_day_boundary'
            when split.recorded_departures_in_gap > 0 then 'departure_recorded_inside'
            when placed.departed_at is null then 'departure_not_recorded'
            else 'no_departure_recorded_inside'
        end as gap_kind
    from placed
    left join gap_start on placed.trip_stop_event_key = gap_start.trip_stop_event_key
    left join split on placed.trip_stop_event_key = split.trip_stop_event_key

)

select
    cast(classified.trip_stop_event_key as varchar) as trip_stop_event_key,
    cast(classified.service_date as date) as service_date,
    cast(classified.date_key as integer) as date_key,
    cast(dates.day_type as varchar) as day_type,
    cast(classified.service_period_id as varchar) as service_period_id,
    cast(classified.line_id as varchar) as line_id,
    cast(classified.route_id as varchar) as route_id,
    cast(classified.direction_id as integer) as direction_id,
    cast(classified.station_id as varchar) as station_id,
    cast(classified.stop_id as varchar) as stop_id,
    cast(classified.headway_seconds as bigint) as gap_seconds,
    cast(classified.scheduled_headway_seconds as bigint) as scheduled_gap_seconds,
    cast(classified.gap_start_at as timestamp) as gap_start_at,
    cast(classified.departed_at as timestamp) as departed_at,
    cast(classified.gap_start_service_date as date) as gap_start_service_date,
    cast(classified.recorded_departures_in_gap as bigint) as recorded_departures_in_gap,
    cast(classified.longest_recorded_piece_seconds as bigint) as longest_recorded_piece_seconds,
    cast(classified.recorded_gap_squared_sum as double) as recorded_gap_squared_sum,
    cast(classified.gap_kind as varchar) as gap_kind,
    cast(classified.gap_kind != 'spans_service_day_boundary' as boolean) as is_passenger_wait
from classified
inner join {{ ref('dim_dates') }} as dates on classified.date_key = dates.date_key
