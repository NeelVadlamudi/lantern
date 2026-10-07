-- Per-line late share and excess seconds on the board (board_line_totals, pooled from the daily
-- mart) equal the per-trip figures from fct_trips. Tolerance 1e-4 and 0.06 s.
with fact as (
    select
        route_id,
        avg(cast(is_late_trip as int)) as late_trip_share,
        avg(trip_excess_seconds) as avg_trip_excess_seconds
    from {{ ref('fct_trips') }}
    where compared_segments > 0
    group by route_id
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
    or fact.route_id is null
    or abs(line_totals.late_trip_share - fact.late_trip_share) > 0.0001
    or abs(line_totals.avg_trip_excess_seconds - fact.avg_trip_excess_seconds) > 0.06
