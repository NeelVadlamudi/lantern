-- Grain: one row per station on the subway network.
-- Whole-window summary for map shading: coordinates, routes served, and reliability weighted by
-- riders. rider_weighted_* values weight each line/day-type/period cell of
-- mart_station_reliability by its estimated gated entries, so busy periods count more.
-- Stations without gated-entry data fall back to unweighted (event-weighted) values and are
-- flagged with has_rider_data = false.

with cells as (

    select * from {{ ref('mart_station_reliability') }}

),

rolled as (

    select
        station_id,
        sum(trip_stop_events) as trip_stop_events,
        sum(headway_observations) as headway_observations,
        sum(avg_excess_travel_seconds * travel_comparisons) / nullif(sum(travel_comparisons), 0)
            as avg_excess_travel_seconds,
        sum(long_gap_share * headway_observations) / nullif(sum(headway_observations), 0)
            as long_gap_share,
        bool_or(has_rider_data) as has_rider_data,
        sum(est_window_gated_entries) as est_window_gated_entries,
        sum(est_window_entries_in_long_gaps) as est_window_entries_in_long_gaps,
        sum(avg_excess_travel_seconds * est_window_gated_entries)
        filter (where avg_excess_travel_seconds is not null)
        / nullif(sum(est_window_gated_entries) filter (where avg_excess_travel_seconds is not null), 0)
            as rider_weighted_excess_seconds,
        sum(long_gap_share * est_window_gated_entries) filter (where long_gap_share is not null)
        / nullif(sum(est_window_gated_entries) filter (where long_gap_share is not null), 0)
            as rider_weighted_long_gap_share,
        max(service_days) as service_days
    from cells
    group by station_id

),

daily_riders as (

    -- average daily entries across all day types, weighted by how often each day type occurs
    select
        station_id,
        sum(est_window_gated_entries) as entries
    from cells
    group by station_id

),

weekday_riders as (

    -- average weekday: each weekday cell is one station, line and service period, so the sum is
    -- one weekday's entries with no double counting across day types
    select
        station_id,
        sum(avg_daily_gated_entries) as weekday_gated_entries,
        sum(avg_daily_gated_entries * long_gap_share) as weekday_entries_in_long_gaps
    from cells
    where day_type = 'weekday'
    group by station_id

),

gated as (

    -- stations present in the gated-entry basis, whether or not trains ran there in the window
    select distinct station_id from {{ ref('int_station_period_riders') }}

),

window_days as (

    select count(*) as n_days from {{ ref('dim_dates') }}

)

select
    stations.station_key,
    cast(stations.station_id as varchar) as station_id,
    cast(stations.station_name as varchar) as station_name,
    cast(stations.latitude as double) as latitude,
    cast(stations.longitude as double) as longitude,
    cast(stations.route_ids as varchar) as route_ids,
    cast(stations.line_ids as varchar) as line_ids,
    cast(coalesce(rolled.trip_stop_events, 0) as bigint) as trip_stop_events,
    cast(coalesce(rolled.headway_observations, 0) as bigint) as headway_observations,
    cast(rolled.avg_excess_travel_seconds as double) as avg_excess_travel_seconds,
    cast(rolled.long_gap_share as double) as long_gap_share,
    cast(coalesce(rolled.has_rider_data, false) as boolean) as has_rider_data,
    cast(daily_riders.entries / window_days.n_days as double) as avg_daily_gated_entries,
    cast(rolled.rider_weighted_excess_seconds as double) as rider_weighted_excess_seconds,
    cast(rolled.rider_weighted_long_gap_share as double) as rider_weighted_long_gap_share,
    cast(coalesce(rolled.rider_weighted_excess_seconds, rolled.avg_excess_travel_seconds) as double)
        as map_excess_seconds,
    cast(coalesce(rolled.rider_weighted_long_gap_share, rolled.long_gap_share) as double)
        as map_long_gap_share,
    cast(rolled.est_window_entries_in_long_gaps / window_days.n_days as double)
        as est_daily_entries_in_long_gaps,
    cast(weekday_riders.weekday_gated_entries as double) as weekday_gated_entries,
    cast(weekday_riders.weekday_entries_in_long_gaps as double) as weekday_entries_in_long_gaps,
    cast(gated.station_id is not null as boolean) as has_gated_entries
from {{ ref('dim_stations') }} as stations
cross join window_days
left join rolled
    on stations.station_id = rolled.station_id
left join daily_riders
    on stations.station_id = daily_riders.station_id
left join weekday_riders
    on stations.station_id = weekday_riders.station_id
left join gated
    on stations.station_id = gated.station_id
where stations.is_on_canonical_pattern
