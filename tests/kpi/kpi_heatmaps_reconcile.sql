-- Hour heatmaps add back up to the day: for every service date, the system rows of
-- mart_line_hour_heatmap sum to the day's compared trips and late trips (fct_trips), compared
-- runs (int_train_runs) and headway observations and long gaps (fct_trip_stop_events), and the
-- station heatmap sums to the same runs and long gaps. Returns the dates that disagree.

with line_hours as (
    select
        service_date,
        sum(trips_compared) as trips_compared,
        sum(late_trips) as late_trips,
        sum(runs_compared) as runs_compared,
        sum(headway_observations) as headway_observations,
        sum(long_gaps) as long_gaps
    from {{ ref('mart_line_hour_heatmap') }}
    where scope_id = 'system'
    group by service_date
),

station_hours as (
    select
        service_date,
        sum(runs_compared) as runs_compared,
        sum(long_gaps) as long_gaps
    from {{ ref('mart_station_hour_heatmap') }}
    group by service_date
),

trips as (
    select
        service_date,
        count(*) filter (where compared_segments > 0) as trips_compared,
        count(*) filter (where is_late_trip) as late_trips
    from {{ ref('fct_trips') }}
    group by service_date
),

runs as (
    select
        service_date,
        count(*) filter (where run_comparison_status = 'compared') as runs_compared
    from {{ ref('int_train_runs') }}
    group by service_date
),

headways as (
    select
        service_date,
        count(*) filter (where has_headway_comparison) as headway_observations,
        count(*) filter (where is_long_gap) as long_gaps
    from {{ ref('fct_trip_stop_events') }}
    group by service_date
)

select trips.service_date
from trips
inner join runs on trips.service_date = runs.service_date
inner join headways on trips.service_date = headways.service_date
left join line_hours on trips.service_date = line_hours.service_date
left join station_hours on trips.service_date = station_hours.service_date
where
    line_hours.trips_compared is distinct from trips.trips_compared
    or line_hours.late_trips is distinct from trips.late_trips
    or line_hours.runs_compared is distinct from runs.runs_compared
    or line_hours.headway_observations is distinct from headways.headway_observations
    or line_hours.long_gaps is distinct from headways.long_gaps
    or station_hours.runs_compared is distinct from runs.runs_compared
    or station_hours.long_gaps is distinct from headways.long_gaps
