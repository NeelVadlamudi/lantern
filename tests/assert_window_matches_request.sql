-- When the window is set with lamp_start_date / lamp_end_date, the loaded dates must start and
-- end on those dates. A missing first or last day (no file in the index for it) otherwise
-- shortens the window without any other test noticing.
{%- set start_date = var('lamp_start_date', none) %}
{%- set end_date = var('lamp_end_date', none) %}
with loaded as (
    select
        min(service_date) as first_date,
        max(service_date) as last_date
    from {{ ref('stg_lamp__subway_trip_stops') }}
)

select
    first_date,
    last_date
from loaded
where
    {% if start_date %}first_date != date '{{ start_date }}'{% else %}false{% endif %}
    or {% if end_date %}last_date != date '{{ end_date }}'{% else %}false{% endif %}
