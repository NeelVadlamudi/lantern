-- Grain: one row per station, line (trunk line: Red, Orange, Blue, Green, Mattapan), day type
-- and service period, over the loaded window.
-- Reliability is measured on trains arriving at the station: excess travel on the segment into
-- the station and the trunk headway at the station. Rider exposure comes from average daily
-- fare-gate entries for the same station, line, day type and period (int_station_period_riders).
-- Gated entries exist only for gated stations, so has_rider_data is false for Green Line surface
-- stops and most Mattapan stops; those rows keep their reliability numbers but no rider weight.

with events as (

    select
        e.*,
        d.day_type
    from {{ ref('fct_trip_stop_events') }} as e
    inner join {{ ref('dim_dates') }} as d
        on e.date_key = d.date_key
    where e.station_id is not null
        and e.service_period_id is not null

),

stats as (

    select
        station_id,
        line_id,
        day_type,
        service_period_id,
        count(distinct service_date) as service_days,
        count(*) as trip_stop_events,
        count(*) filter (where has_travel_comparison) as travel_comparisons,
        avg(excess_travel_seconds) as avg_excess_travel_seconds,
        count(*) filter (where has_headway_comparison) as headway_observations,
        avg(cast(is_long_gap as int)) filter (where has_headway_comparison) as long_gap_share,
        avg(cast(is_headway_adherent as int)) filter (where has_headway_comparison) as headway_adherence_share,
        median(headway_seconds) filter (where has_headway_comparison) as median_headway_seconds,
        median(scheduled_headway_seconds) filter (where has_headway_comparison) as median_scheduled_headway_seconds
    from events
    group by station_id, line_id, day_type, service_period_id

),

riders as (

    select * from {{ ref('int_station_period_riders') }}

)

select
    {{ dbt_utils.generate_surrogate_key([
        'stats.station_id', 'stats.line_id', 'stats.day_type', 'stats.service_period_id'
    ]) }} as station_period_key,
    cast(stats.station_id as varchar) as station_id,
    cast(stats.line_id as varchar) as line_id,
    cast(stats.day_type as varchar) as day_type,
    cast(stats.service_period_id as varchar) as service_period_id,
    cast(stats.service_days as bigint) as service_days,
    cast(stats.trip_stop_events as bigint) as trip_stop_events,
    cast(stats.travel_comparisons as bigint) as travel_comparisons,
    cast(stats.avg_excess_travel_seconds as double) as avg_excess_travel_seconds,
    cast(stats.headway_observations as bigint) as headway_observations,
    cast(stats.long_gap_share as double) as long_gap_share,
    cast(stats.headway_adherence_share as double) as headway_adherence_share,
    cast(stats.median_headway_seconds as double) as median_headway_seconds,
    cast(stats.median_scheduled_headway_seconds as double) as median_scheduled_headway_seconds,
    riders.station_id is not null as has_rider_data,
    cast(riders.avg_daily_gated_entries as double) as avg_daily_gated_entries,
    -- estimated entries during this cell over the whole window: daily average x service days
    cast(riders.avg_daily_gated_entries * stats.service_days as double) as est_window_gated_entries,
    -- exposure index: estimated entries made while trains here were running a long gap
    cast(riders.avg_daily_gated_entries * stats.service_days * stats.long_gap_share as double)
        as est_window_entries_in_long_gaps,
    cast(riders.basis_start_date as date) as rider_basis_start_date,
    cast(riders.basis_end_date as date) as rider_basis_end_date
from stats
left join riders
    on stats.station_id = riders.station_id
        and stats.line_id = riders.line_id
        and stats.day_type = riders.day_type
        and stats.service_period_id = riders.service_period_id
