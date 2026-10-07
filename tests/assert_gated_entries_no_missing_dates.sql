{{ config(severity='warn') }}
-- Dates with no gated-entry rows between the first and last date in the feed.
with bounds as (
    select
        min(service_date) as first_date,
        max(service_date) as last_date
    from {{ ref('stg_mbta__gated_entries') }}
),

dates as (
    select cast(unnest(generate_series(first_date, last_date, interval 1 day)) as date) as service_date
    from bounds
),

present as (
    select distinct service_date from {{ ref('stg_mbta__gated_entries') }}
)

select dates.service_date
from dates
left join present on dates.service_date = present.service_date
where present.service_date is null
