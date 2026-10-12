-- Grain: one row per line (GTFS route) and service date.
-- Trip measures are per train run (fct_trips), over trips with at least one compared segment,
-- the same grain as the systemwide figures. Longer lines collect more excess per trip, so
-- excess_share_of_scheduled (excess / scheduled run time) is included to compare lines fairly.
-- The *_sum and count columns are additive across dates; shares and averages are not.
-- day_type (weekday / saturday / sunday / holiday) comes from dim_dates.
-- Stop-to-stop runs over 30 minutes are included in every measure. long_run_* gives their part
-- and *_excl_long_runs the same trip measures without them (the definition before they were
-- included), so both views come from one table.

with events as (

    select * from {{ ref('fct_trip_stop_events') }}

),

trips as (

    select * from {{ ref('fct_trips') }}

),

event_stats as (

    select
        route_id,
        service_date,
        count(*) as trip_stop_events,
        count(*) filter (where has_travel_comparison) as travel_comparisons,
        avg(excess_travel_seconds) as avg_excess_travel_seconds,
        median(excess_travel_seconds) as median_excess_travel_seconds,
        quantile_cont(excess_travel_seconds, 0.9) as p90_excess_travel_seconds,
        count(*) filter (where has_headway_comparison) as headway_observations,
        count(*) filter (where has_headway_comparison and is_long_gap) as long_gaps,
        avg(cast(is_long_gap as int)) filter (where has_headway_comparison) as long_gap_share,
        avg(cast(is_bunched as int)) filter (where has_headway_comparison) as bunched_share,
        avg(cast(is_headway_adherent as int)) filter (where has_headway_comparison) as headway_adherence_share,
        median(headway_ratio) as median_headway_ratio
    from events
    group by route_id, service_date

),

trip_stats as (

    select
        route_id,
        service_date,
        count(*) as trips,
        count(*) filter (where compared_segments > 0) as trips_compared,
        avg(trip_excess_seconds) filter (where compared_segments > 0) as avg_trip_excess_seconds,
        count(*) filter (where compared_segments > 0 and is_late_trip) as late_trips,
        sum(trip_excess_seconds) filter (where compared_segments > 0) as trip_excess_seconds_sum,
        sum(trip_scheduled_seconds) filter (where compared_segments > 0) as trip_scheduled_seconds_sum,
        avg(cast(is_late_trip as int)) filter (where compared_segments > 0) as late_trip_share,
        sum(long_run_segments) as long_run_comparisons,
        count(*) filter (where long_run_segments > 0) as trips_with_long_runs,
        sum(long_run_excess_seconds) as long_run_excess_seconds_sum,
        count(*) filter (where compared_segments_excl_long_runs > 0) as trips_compared_excl_long_runs,
        count(*) filter (where compared_segments_excl_long_runs > 0 and is_late_trip_excl_long_runs)
            as late_trips_excl_long_runs,
        avg(trip_excess_seconds_excl_long_runs) filter (where compared_segments_excl_long_runs > 0)
            as avg_trip_excess_seconds_excl_long_runs,
        sum(trip_excess_seconds_excl_long_runs) filter (where compared_segments_excl_long_runs > 0)
            as trip_excess_seconds_sum_excl_long_runs,
        sum(trip_scheduled_seconds_excl_long_runs) filter (where compared_segments_excl_long_runs > 0)
            as trip_scheduled_seconds_sum_excl_long_runs
    from trips
    group by route_id, service_date

)

select
    {{ dbt_utils.generate_surrogate_key(['event_stats.route_id', 'event_stats.service_date']) }} as line_day_key,
    cast(event_stats.route_id as varchar) as route_id,
    cast(event_stats.service_date as date) as service_date,
    cast(strftime(event_stats.service_date, '%Y%m%d') as integer) as date_key,
    cast(dates.day_type as varchar) as day_type,
    cast(trip_stats.trips as bigint) as trips,
    cast(trip_stats.trips_compared as bigint) as trips_compared,
    cast(event_stats.trip_stop_events as bigint) as trip_stop_events,
    cast(event_stats.travel_comparisons as bigint) as travel_comparisons,
    cast(trip_stats.avg_trip_excess_seconds as double) as avg_trip_excess_seconds,
    cast(trip_stats.late_trip_share as double) as late_trip_share,
    cast(trip_stats.late_trips as bigint) as late_trips,
    cast(trip_stats.trip_excess_seconds_sum as bigint) as trip_excess_seconds_sum,
    cast(trip_stats.trip_scheduled_seconds_sum as bigint) as trip_scheduled_seconds_sum,
    cast(
        trip_stats.trip_excess_seconds_sum / nullif(trip_stats.trip_scheduled_seconds_sum, 0) as double
    ) as excess_share_of_scheduled,
    cast(event_stats.avg_excess_travel_seconds as double) as avg_excess_travel_seconds,
    cast(event_stats.median_excess_travel_seconds as double) as median_excess_travel_seconds,
    cast(event_stats.p90_excess_travel_seconds as double) as p90_excess_travel_seconds,
    cast(event_stats.headway_observations as bigint) as headway_observations,
    cast(event_stats.long_gaps as bigint) as long_gaps,
    cast(event_stats.long_gap_share as double) as long_gap_share,
    cast(event_stats.bunched_share as double) as bunched_share,
    cast(event_stats.headway_adherence_share as double) as headway_adherence_share,
    cast(event_stats.median_headway_ratio as double) as median_headway_ratio,
    cast(coalesce(trip_stats.long_run_comparisons, 0) as bigint) as long_run_comparisons,
    cast(coalesce(trip_stats.trips_with_long_runs, 0) as bigint) as trips_with_long_runs,
    cast(coalesce(trip_stats.long_run_excess_seconds_sum, 0) as bigint) as long_run_excess_seconds_sum,
    cast(coalesce(trip_stats.trips_compared_excl_long_runs, 0) as bigint) as trips_compared_excl_long_runs,
    cast(coalesce(trip_stats.late_trips_excl_long_runs, 0) as bigint) as late_trips_excl_long_runs,
    cast(
        trip_stats.late_trips_excl_long_runs / nullif(trip_stats.trips_compared_excl_long_runs, 0) as double
    ) as late_trip_share_excl_long_runs,
    cast(trip_stats.avg_trip_excess_seconds_excl_long_runs as double) as avg_trip_excess_seconds_excl_long_runs,
    cast(trip_stats.trip_excess_seconds_sum_excl_long_runs as bigint) as trip_excess_seconds_sum_excl_long_runs,
    cast(trip_stats.trip_scheduled_seconds_sum_excl_long_runs as bigint)
        as trip_scheduled_seconds_sum_excl_long_runs
from event_stats
left join trip_stats
    on event_stats.route_id = trip_stats.route_id
        and event_stats.service_date = trip_stats.service_date
inner join {{ ref('dim_dates') }} as dates
    on event_stats.service_date = dates.date_day
