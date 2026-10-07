-- Each station x line x day type x service period rider cell appears once, so no gate entry is
-- counted twice in the rider tile.
select
    station_id,
    line_id,
    day_type,
    service_period_id,
    count(*) as n
from {{ ref('int_station_period_riders') }}
group by all
having count(*) > 1
