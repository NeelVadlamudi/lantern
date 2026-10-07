-- Grain: one row per MBTA service period (Service Delivery Policy, Dec 2025, Table 1).

select
    cast(service_period_id as varchar) as service_period_id,
    cast(service_period_name as varchar) as service_period_name,
    cast(start_minute as integer) as start_minute,
    cast(end_minute as integer) as end_minute,
    cast(
        lpad(cast(start_minute // 60 as varchar), 2, '0') || ':' || lpad(cast(start_minute % 60 as varchar), 2, '0')
        || '-'
        || lpad(cast(end_minute // 60 as varchar), 2, '0') || ':' || lpad(cast(end_minute % 60 as varchar), 2, '0')
        as varchar
    ) as clock_range,
    cast(sort_order as integer) as sort_order
from {{ ref('service_periods') }}
