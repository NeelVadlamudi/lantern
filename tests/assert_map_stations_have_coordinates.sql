-- Every station the board draws (line stop sequences and station overview) needs coordinates.
select
    'mart_line_stop_sequence' as model_name,
    station_id
from {{ ref('mart_line_stop_sequence') }}
where latitude is null or longitude is null

union all

select
    'mart_station_overview' as model_name,
    station_id
from {{ ref('mart_station_overview') }}
where latitude is null or longitude is null
