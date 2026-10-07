{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_periods.parquet'
    )
}}
-- Board file: reliability by line, day type and service period (mart_period_reliability).

select
    p.route_id,
    p.day_type,
    p.service_period_id,
    sp.sort_order as service_period_order,
    p.service_days,
    p.trips_compared,
    round(p.avg_trip_excess_seconds, 1) as avg_trip_excess_seconds,
    round(p.late_trip_share, 4) as late_trip_share,
    round(p.median_excess_travel_seconds, 1) as median_excess_travel_seconds,
    p.headway_observations,
    round(p.long_gap_share, 4) as long_gap_share,
    round(p.bunched_share, 4) as bunched_share,
    round(p.headway_adherence_share, 4) as headway_adherence_share,
    p.median_headway_seconds,
    p.median_scheduled_headway_seconds
from {{ ref('mart_period_reliability') }} as p
inner join {{ ref('dim_service_periods') }} as sp
    on p.service_period_id = sp.service_period_id
order by p.route_id, p.day_type, sp.sort_order
