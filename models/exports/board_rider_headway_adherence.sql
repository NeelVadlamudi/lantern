{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/rider_headway_adherence.parquet'
    )
}}
-- Board file: rider-weighted headway adherence per scope, day type and MBTA service period
-- (mart_rider_headway_adherence), with display names and period order. An estimate: weights are
-- fare-gate entries, split 50/50 by direction, with one shared rate at stations without gates.

select
    adherence.scope_id,
    case
        when adherence.scope_id = 'Green' then 'Green Line (all branches)'
        else coalesce(routes.display_name, 'All subway lines')
    end as scope_name,
    adherence.day_type,
    adherence.service_period_id,
    periods.service_period_name,
    periods.sort_order as service_period_sort_order,
    adherence.service_days,
    adherence.departures,
    adherence.departures_at_gated_stations,
    adherence.departures_at_green_trunk,
    adherence.departures_weighted,
    adherence.est_riders,
    adherence.est_riders_within_allowance,
    adherence.rider_weighted_share,
    adherence.unweighted_share,
    adherence.departure_share
from {{ ref('mart_rider_headway_adherence') }} as adherence
left join {{ ref('dim_routes') }} as routes on adherence.scope_id = routes.route_id
left join {{ ref('service_periods') }} as periods on adherence.service_period_id = periods.service_period_id
order by coalesce(routes.display_order, 0), adherence.day_type, periods.sort_order
