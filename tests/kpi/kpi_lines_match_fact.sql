-- Matched trips only (trip id in the day's schedule), planned-change line-days excluded.
-- Per-line late share and excess seconds on the board (board_line_totals, pooled from the daily
-- mart) equal the per-trip figures from fct_trips. Tolerance 1e-4 and 0.06 s.
with fact as (
    select
        trips.route_id,
        avg(cast(trips.is_late_trip as int)) as late_trip_share,
        avg(trips.trip_excess_seconds) as avg_trip_excess_seconds
    from {{ ref('fct_trips') }} as trips
    inner join {{ ref('mart_planned_change_line_days') }} as planned
        on trips.route_id = planned.route_id and trips.service_date = planned.service_date
    where trips.compared_segments > 0 and trips.is_matched_trip and not planned.is_planned_change
    group by trips.route_id
)

select
    coalesce(line_totals.route_id, fact.route_id) as route_id,
    line_totals.late_trip_share as board_late,
    fact.late_trip_share as fact_late,
    line_totals.avg_trip_excess_seconds as board_excess,
    fact.avg_trip_excess_seconds as fact_excess
from {{ ref('board_line_totals') }} as line_totals
full outer join fact on line_totals.route_id = fact.route_id
where
    line_totals.route_id is null
    or (fact.route_id is null and line_totals.trips_compared is not null)
    or abs(line_totals.late_trip_share - fact.late_trip_share) > 0.0001
    or abs(line_totals.avg_trip_excess_seconds - fact.avg_trip_excess_seconds) > 0.06
