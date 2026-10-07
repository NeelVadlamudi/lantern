-- Every fact row must fall inside the service dates actually loaded in raw.
with bounds as (
    select
        cast(strptime(cast(min(service_date) as varchar), '%Y%m%d') as date) as first_date,
        cast(strptime(cast(max(service_date) as varchar), '%Y%m%d') as date) as last_date
    from {{ source('lamp', 'lamp_subway_on_time') }}
)

select f.service_date
from {{ ref('fct_trip_stop_events') }} as f
cross join bounds
where f.service_date < bounds.first_date or f.service_date > bounds.last_date
group by f.service_date
