-- Every loaded LAMP service date needs a GTFS version (canonical route patterns) active on it.
-- Fails when the window reaches a year not listed in var('gtfs_years').
select lamp.service_date
from (select distinct service_date from {{ ref('stg_lamp__subway_trip_stops') }}) as lamp
where not exists (
        select 1
        from {{ ref('stg_gtfs__route_patterns') }} as rp
        where
            rp.is_canonical
            and lamp.service_date between rp.valid_from_date and rp.valid_to_date
    )
