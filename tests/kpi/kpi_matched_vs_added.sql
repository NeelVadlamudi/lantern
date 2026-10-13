-- Late share uses matched trips only (trip id in the GTFS schedule for the date); unmatched and
-- added runs are counted separately and add back up to every compared run. Per route over
-- line-days without a planned change, board_line_totals equals fct_trips; the late tile carries
-- the same system counts.
with fact as (
    select
        trips.route_id,
        count(*) filter (where trips.is_matched_trip) as matched_compared,
        count(*) filter (where trips.is_matched_trip and trips.is_late_trip) as matched_late,
        count(*) filter (where not trips.is_matched_trip) as unmatched_compared,
        count(*) filter (where not trips.is_matched_trip and trips.is_added_trip) as added_compared
    from {{ ref('fct_trips') }} as trips
    inner join {{ ref('mart_planned_change_line_days') }} as planned
        on trips.route_id = planned.route_id and trips.service_date = planned.service_date
    where trips.compared_segments > 0 and not planned.is_planned_change
    group by trips.route_id
),

system_fact as (
    select
        sum(matched_compared) as matched_compared,
        sum(matched_late) as matched_late,
        sum(unmatched_compared) as unmatched_compared,
        sum(added_compared) as added_compared
    from fact
)

select
    'line totals' as check_name,
    fact.route_id
from fact
left join {{ ref('board_line_totals') }} as totals on fact.route_id = totals.route_id
where
    totals.trips_compared is distinct from fact.matched_compared
    or totals.late_trips is distinct from fact.matched_late
    or totals.unmatched_trips_compared is distinct from fact.unmatched_compared
    or totals.added_trips_compared is distinct from fact.added_compared

union all

select
    'late tile counts' as check_name,
    'system' as route_id
from {{ ref('board_tiles') }} as tiles
cross join system_fact
where
    tiles.tile_id = 'late_trip_share'
    and (
        cast(tiles.tile ->> 'trips_compared' as bigint) != system_fact.matched_compared
        or cast(tiles.tile ->> 'late_trips' as bigint) != system_fact.matched_late
        or cast(tiles.tile ->> 'unmatched_trips_compared' as bigint) != system_fact.unmatched_compared
        or cast(tiles.tile ->> 'added_trips_compared' as bigint) != system_fact.added_compared
    )

union all

select
    'daily all = matched + unmatched' as check_name,
    route_id
from {{ ref('mart_line_daily_reliability') }}
where all_trips_compared != trips_compared + unmatched_trips_compared
    or added_trips_compared > unmatched_trips_compared
