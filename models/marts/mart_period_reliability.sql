-- Grain: one row per line (GTFS route), day type and service period, over the loaded window.

with events as (

    select
        e.*,
        d.day_type
    from {{ ref('fct_trip_stop_events') }} as e
    inner join {{ ref('dim_dates') }} as d
        on e.date_key = d.date_key

),

trips as (

    select
        t.*,
        d.day_type
    from {{ ref('fct_trips') }} as t
    inner join {{ ref('dim_dates') }} as d
        on t.date_key = d.date_key

),

event_stats as (

    select
        route_id,
        day_type,
        service_period_id,
        count(distinct service_date) as service_days,
        count(*) as trip_stop_events,
        count(*) filter (where has_travel_comparison) as travel_comparisons,
        avg(excess_travel_seconds) as avg_excess_travel_seconds,
        median(excess_travel_seconds) as median_excess_travel_seconds,
        count(*) filter (where has_headway_comparison) as headway_observations,
        avg(cast(is_long_gap as int)) filter (where has_headway_comparison) as long_gap_share,
        avg(cast(is_bunched as int)) filter (where has_headway_comparison) as bunched_share,
        avg(cast(is_headway_adherent as int)) filter (where has_headway_comparison) as headway_adherence_share,
        median(headway_seconds) filter (where has_headway_comparison) as median_headway_seconds,
        median(scheduled_headway_seconds) filter (where has_headway_comparison) as median_scheduled_headway_seconds
    from events
    where service_period_id is not null
    group by route_id, day_type, service_period_id

),

trip_stats as (

    -- trips are assigned to the period they started in
    select
        route_id,
        day_type,
        start_service_period_id as service_period_id,
        count(*) filter (where compared_segments > 0) as trips_compared,
        avg(trip_excess_seconds) filter (where compared_segments > 0) as avg_trip_excess_seconds,
        avg(cast(is_late_trip as int)) filter (where compared_segments > 0) as late_trip_share
    from trips
    group by route_id, day_type, start_service_period_id

)

select
    {{ dbt_utils.generate_surrogate_key([
        'event_stats.route_id', 'event_stats.day_type', 'event_stats.service_period_id'
    ]) }} as line_period_key,
    cast(event_stats.route_id as varchar) as route_id,
    cast(event_stats.day_type as varchar) as day_type,
    cast(event_stats.service_period_id as varchar) as service_period_id,
    cast(event_stats.service_days as bigint) as service_days,
    cast(trip_stats.trips_compared as bigint) as trips_compared,
    cast(event_stats.trip_stop_events as bigint) as trip_stop_events,
    cast(event_stats.travel_comparisons as bigint) as travel_comparisons,
    cast(trip_stats.avg_trip_excess_seconds as double) as avg_trip_excess_seconds,
    cast(trip_stats.late_trip_share as double) as late_trip_share,
    cast(event_stats.avg_excess_travel_seconds as double) as avg_excess_travel_seconds,
    cast(event_stats.median_excess_travel_seconds as double) as median_excess_travel_seconds,
    cast(event_stats.headway_observations as bigint) as headway_observations,
    cast(event_stats.long_gap_share as double) as long_gap_share,
    cast(event_stats.bunched_share as double) as bunched_share,
    cast(event_stats.headway_adherence_share as double) as headway_adherence_share,
    cast(event_stats.median_headway_seconds as double) as median_headway_seconds,
    cast(event_stats.median_scheduled_headway_seconds as double) as median_scheduled_headway_seconds
from event_stats
left join trip_stats
    on event_stats.route_id = trip_stats.route_id
        and event_stats.day_type = trip_stats.day_type
        and event_stats.service_period_id = trip_stats.service_period_id
