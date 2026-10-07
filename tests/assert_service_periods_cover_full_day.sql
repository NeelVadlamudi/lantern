-- The service period seed must cover all 1440 minutes of the clock day exactly once.
select count(*) as minutes
from {{ ref('int_service_periods') }}
having count(*) != 1440
