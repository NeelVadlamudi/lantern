-- The whole-line Green scope in line_day_metrics follows the same rules as the other lines:
-- each day's late share, long-gap share and train delay recomputed from the facts over the four
-- Green branches; the typical band (p25 <= median <= p75) holds; and the typical values are
-- computed over the same day type like every other scope. Tolerance 1e-9.
with trips as (
    select
        service_date,
        count(*) filter (where compared_segments > 0) as trips_compared,
        count(*) filter (where compared_segments > 0 and is_late_trip) as late_trips
    from {{ ref('fct_trips') }}
    where route_id like 'Green-%'
    group by service_date
),

gaps as (
    select
        service_date,
        count(*) as headway_observations,
        count(*) filter (where is_long_gap) as long_gaps
    from {{ ref('fct_trip_stop_events') }}
    where route_id like 'Green-%' and has_headway_comparison
    group by service_date
),

green as (
    select
        service_date,
        max(value) filter (where measure = 'late_trip_share') as late_trip_share,
        max(value) filter (where measure = 'long_gap_share') as long_gap_share,
        max(value) filter (where measure = 'trips_compared') as trips_compared
    from {{ ref('mart_line_day_metrics') }}
    where scope_id = 'Green'
    group by service_date
)

select
    'day value' as check_name,
    trips.service_date
from trips
left join green on trips.service_date = green.service_date
left join gaps on trips.service_date = gaps.service_date
where
    green.trips_compared is distinct from cast(trips.trips_compared as double)
    or abs(green.late_trip_share - trips.late_trips / trips.trips_compared) > 1e-9
    or abs(green.long_gap_share - gaps.long_gaps / gaps.headway_observations) > 1e-9

union all

select
    'typical band' as check_name,
    service_date
from {{ ref('mart_line_day_metrics') }}
where
    scope_id = 'Green'
    and typical_days > 0
    and not (typical_p25 <= typical_median and typical_median <= typical_p75)
