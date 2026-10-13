{{ config(materialized='table') }}

-- Grain: one row per alert version, informed entity and active period (as published in
-- LAMP_RT_ALERTS), subway and light rail only (route_type 1 and 0). Facility alerts
-- (elevators, escalators: effect ACCESSIBILITY_ISSUE) are left out. Datetimes are local
-- (America/New_York) wall-clock times, as LAMP publishes them.

with source as (

    select * from {{ source('lamp', 'lamp_rt_alerts') }}

)

select distinct
    cast(id as bigint) as alert_id,
    cast(last_modified_timestamp as bigint) as alert_version_timestamp,
    cast(created_datetime as timestamp) as created_at,
    cast(closed_datetime as timestamp) as closed_at,
    cast(cause as varchar) as cause,
    cast(effect as varchar) as effect,
    cast(effect_detail as varchar) as effect_detail,
    cast(severity_level as varchar) as severity_level,
    cast("header_text.translation.text" as varchar) as header_text,
    cast("active_period.start_datetime" as timestamp) as active_start_at,
    cast("active_period.end_datetime" as timestamp) as active_end_at,
    cast("informed_entity.route_id" as varchar) as route_id,
    cast("informed_entity.route_type" as integer) as route_type,
    cast("informed_entity.direction_id" as integer) as direction_id,
    nullif(cast("informed_entity.stop_id" as varchar), '') as stop_id
from source
where
    "informed_entity.route_type" in (0, 1)  -- noqa: RF05
    and effect is distinct from 'ACCESSIBILITY_ISSUE'
