-- Grain: one row per track segment and service date with at least one train run compared to
-- the schedule. Daily excess run time and rider-weighted loss (an estimate, exact seconds):
-- per service period, gated entries at the start station * segment excess sum / train
-- departures from that station (mart_station_rider_time_lost), summed over periods. Null
-- rider_seconds_lost when the start station has no rider weight that day.

with traversals as (

    select * from {{ ref('fct_segment_traversals') }}

),

station_cells as (

    select
        station_id,
        line_id,
        date_key,
        service_period_id,
        segment_departures,
        gated_entries
    from {{ ref('mart_station_rider_time_lost') }}

),

segment_periods as (

    select
        segment_id,
        line_id,
        from_station_id,
        service_date,
        date_key,
        day_type,
        service_period_id,
        count(*) as traversals,
        sum(excess_travel_seconds) as excess_travel_seconds_sum
    from traversals
    group by all

)

select
    {{ dbt_utils.generate_surrogate_key(['segment_periods.segment_id', 'segment_periods.date_key']) }}
        as segment_day_key,
    cast(segment_periods.segment_id as varchar) as segment_id,
    cast(segment_periods.line_id as varchar) as line_id,
    cast(segment_periods.service_date as date) as service_date,
    cast(segment_periods.date_key as integer) as date_key,
    cast(segment_periods.day_type as varchar) as day_type,
    cast(sum(segment_periods.traversals) as bigint) as traversals,
    cast(sum(segment_periods.excess_travel_seconds_sum) as bigint) as excess_travel_seconds_sum,
    cast(
        sum(segment_periods.excess_travel_seconds_sum) / sum(segment_periods.traversals) as double
    ) as avg_excess_travel_seconds,
    cast(count(station_cells.gated_entries) > 0 as boolean) as has_rider_data,
    cast(
        sum(
            station_cells.gated_entries * segment_periods.excess_travel_seconds_sum
            / station_cells.segment_departures
        ) as double
    ) as rider_seconds_lost
from segment_periods
inner join station_cells
    on
        segment_periods.from_station_id = station_cells.station_id
        and segment_periods.line_id = station_cells.line_id
        and segment_periods.date_key = station_cells.date_key
        and segment_periods.service_period_id = station_cells.service_period_id
group by
    segment_periods.segment_id, segment_periods.line_id, segment_periods.service_date,
    segment_periods.date_key, segment_periods.day_type
