{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/line_daily.parquet'
    )
}}
-- Board file: daily reliability per line (mart_line_daily_reliability + route display fields).
-- Grain: one row per route and service date.

select
    d.route_id,
    r.line_id,
    r.display_name,
    r.route_color_hex,
    d.service_date,
    d.trips,
    d.trips_compared,
    d.trip_stop_events,
    round(d.avg_trip_excess_seconds, 1) as avg_trip_excess_seconds,
    round(d.late_trip_share, 4) as late_trip_share,
    d.late_trips,
    d.trip_excess_seconds_sum,
    d.trip_scheduled_seconds_sum,
    round(d.excess_share_of_scheduled, 4) as excess_share_of_scheduled,
    round(d.median_excess_travel_seconds, 1) as median_excess_travel_seconds,
    round(d.p90_excess_travel_seconds, 1) as p90_excess_travel_seconds,
    d.headway_observations,
    d.long_gaps,
    round(d.long_gap_share, 4) as long_gap_share,
    round(d.bunched_share, 4) as bunched_share,
    round(d.headway_adherence_share, 4) as headway_adherence_share
from {{ ref('mart_line_daily_reliability') }} as d
inner join {{ ref('dim_routes') }} as r
    on d.route_id = r.route_id
order by r.display_order, d.service_date
