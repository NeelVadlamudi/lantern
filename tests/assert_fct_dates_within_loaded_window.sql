-- Every fact row must fall inside the service dates read from LAMP, and every date read must be
-- a file listed in the LAMP index.
with bounds as (
    select
        min(service_date) as first_date,
        max(service_date) as last_date
    from {{ ref('stg_lamp__subway_trip_stops') }}
),

fact_outside as (
    select f.service_date
    from {{ ref('fct_trip_stop_events') }} as f
    cross join bounds
    where f.service_date < bounds.first_date or f.service_date > bounds.last_date
    group by f.service_date
),

not_in_index as (
    select distinct s.service_date
    from {{ ref('stg_lamp__subway_trip_stops') }} as s
    where s.service_date not in (select cast(i.service_date as date) from {{ source('lamp', 'lamp_index') }} as i)
)

select service_date from fact_outside
union all
select service_date from not_in_index
