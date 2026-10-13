{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/suspension_gaps.parquet'
    )
}}
-- Board file: every gap over 1 hour between trains at a platform, with the check against the
-- recorded departures (fct_suspension_gaps). Grain: one row per departure that ended such a gap.
-- Exact seconds plus labels.

select
    gaps.service_date,
    gaps.day_type,
    coalesce(planned.is_planned_change, false) as is_planned_change,
    gaps.service_period_id,
    gaps.line_id,
    gaps.route_id,
    gaps.direction_id,
    gaps.station_id,
    stations.station_name,
    gaps.stop_id,
    gaps.gap_start_at,
    gaps.departed_at,
    gaps.gap_seconds,
    {{ format_duration('gaps.gap_seconds') }} as gap_label,
    gaps.scheduled_gap_seconds,
    {{ format_duration('gaps.scheduled_gap_seconds') }} as scheduled_gap_label,
    gaps.recorded_departures_in_gap,
    gaps.longest_recorded_piece_seconds,
    {{ format_duration('gaps.longest_recorded_piece_seconds') }} as longest_recorded_piece_label,
    gaps.gap_kind,
    gaps.is_passenger_wait
from {{ ref('fct_suspension_gaps') }} as gaps
left join {{ ref('dim_stations') }} as stations on gaps.station_id = stations.station_id
left join {{ ref('mart_planned_change_scope_days') }} as planned
    on
        planned.scope_type = 'route'
        and gaps.route_id = planned.scope_id
        and gaps.service_date = planned.service_date
order by gaps.service_date, gaps.station_id, gaps.stop_id, gaps.departed_at, gaps.trip_stop_event_key
