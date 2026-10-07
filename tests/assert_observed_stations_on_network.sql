-- Every station seen in LAMP should be on a canonical route pattern, so the map can place it.
select
    station_id,
    station_name
from {{ ref('dim_stations') }}
where is_observed_in_lamp and not is_on_canonical_pattern
