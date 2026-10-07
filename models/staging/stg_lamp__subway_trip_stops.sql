{{
    config(
        materialized='incremental',
        unique_key='service_date',
        incremental_strategy='delete+insert',
        on_schema_change='fail'
    )
}}
-- depends_on: {{ source('lamp', 'lamp_index') }}

-- Grain: one row per service date, trip, route, vehicle and stop.
-- Reads the LAMP subway Parquet files straight from their URLs (DuckDB httpfs). The file list
-- comes from the LAMP index via lamp_files_to_load(): on an incremental run, every service date
-- from (latest loaded date - incremental_lookback_days) to the latest complete date is re-read
-- and replaced (delete+insert on service_date), because LAMP republishes recent files.
-- Stored as a table so downstream models never touch the network.
-- LAMP's documented grain is trip-stop per service date, but the files carry a small number
-- of repeated trip-stop rows (the same trip id reused on a second branch, or re-reported).
-- Those are deduplicated here.

{%- set files = lamp_files_to_load() %}
{%- set file_list = "['" ~ files | join("', '") ~ "']" %}
{%- if files | length == 0 and is_incremental() %}

select * from {{ this }} where false

{%- else %}

    with source as (

        select *
        from read_parquet({{ file_list }}, union_by_name = true)

    ),

    renamed as (

        select
            cast(strptime(cast(service_date as varchar), '%Y%m%d') as date) as service_date,
            trip_id,
            route_id,
            coalesce(branch_route_id, route_id) as branch_route_id,
            trunk_route_id as line_id,
            cast(direction_id as integer) as direction_id,
            direction,
            direction_destination,
            vehicle_id,
            vehicle_label,
            stop_id,
            parent_station as station_id,
            stop_sequence,
            stop_count,
            start_time as trip_start_seconds,
            to_timestamp(move_timestamp) as moved_at,
            to_timestamp(stop_timestamp) as stopped_at,
            travel_time_seconds,
            dwell_time_seconds,
            headway_trunk_seconds,
            headway_branch_seconds,
            scheduled_arrival_time as scheduled_arrival_seconds,
            scheduled_departure_time as scheduled_departure_seconds,
            scheduled_travel_time as scheduled_travel_seconds,
            scheduled_headway_trunk as scheduled_headway_trunk_seconds,
            scheduled_headway_branch as scheduled_headway_branch_seconds,
            starts_with(trip_id, 'ADDED-') as is_added_trip,
            current_timestamp at time zone 'UTC' as _loaded_at
        from source

    ),

    deduplicated as (

        select *
        from renamed
        qualify row_number() over (
                partition by service_date, trip_id, route_id, vehicle_label, stop_id
                order by stopped_at asc nulls last, moved_at asc nulls last, _loaded_at desc
            ) = 1

    )

    select
        {{ dbt_utils.generate_surrogate_key(['service_date', 'trip_id', 'route_id', 'vehicle_label', 'stop_id']) }}
            as trip_stop_event_key,
        *
    from deduplicated

{%- endif %}
