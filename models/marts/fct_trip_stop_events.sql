{{
    config(
        materialized='incremental',
        unique_key='trip_stop_event_key',
        incremental_strategy='delete+insert',
        on_schema_change='fail'
    )
}}

-- Grain: one row per service date, trip, route, vehicle and stop (a train arriving at a stop).
-- Incremental on service_date. Each run reprocesses the last var('incremental_lookback_days')
-- loaded service dates, because LAMP republishes recent files after late data arrives.

with events as (

    select * from {{ ref('int_trip_stops__performance') }}

    {% if is_incremental() %}
        where service_date >= (
                select max(this_fct.service_date) - {{ var('incremental_lookback_days') }}
                from {{ this }} as this_fct
            )
    {% endif %}

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
