{{ config(materialized='table') }}
-- Board line totals: one row per subway route over the whole service-date window, pooled
-- from the daily line mart with the denominators as weights (trips_compared for trip
-- measures, headway_observations for gap measures). Feeds the `lines` block and the
-- worst-line tile of board_data.json, and the tests in tests/kpi/.
-- Line-days with a planned service change (mart_planned_change_line_days) are left out of every
-- pooled figure; planned_change_days counts them and *_incl_planned gives the late share with
-- them, for reference.

with all_days as (

    select
        route_id,
        count(*) filter (where is_planned_change) as planned_change_days,
        count(*) as service_days,
        sum(late_trips) / sum(trips_compared) as late_trip_share_incl_planned,
        sum(late_trips) as late_trips_incl_planned,
        sum(trips_compared) as trips_compared_incl_planned
    from {{ ref('mart_line_daily_reliability') }}
    group by route_id

),

normal_days as (

    select * from {{ ref('mart_line_daily_reliability') }}
    where not is_planned_change

)

select
    all_days.route_id,
    routes.display_name,
    routes.line_id,
    routes.route_color_hex,
    routes.display_order,
    cast(all_days.service_days as bigint) as service_days,
    cast(all_days.planned_change_days as bigint) as planned_change_days,
    cast(all_days.late_trip_share_incl_planned as double) as late_trip_share_incl_planned,
    cast(all_days.late_trips_incl_planned as bigint) as late_trips_incl_planned,
    cast(all_days.trips_compared_incl_planned as bigint) as trips_compared_incl_planned,
    cast(sum(daily.trips) as bigint) as trips,
    cast(sum(daily.unmatched_trips_compared) as bigint) as unmatched_trips_compared,
    cast(sum(daily.added_trips_compared) as bigint) as added_trips_compared,
    cast(sum(daily.trips_compared) as bigint) as trips_compared,
    cast(sum(daily.headway_observations) as bigint) as headway_observations,
    sum(daily.late_trip_share * daily.trips_compared)
    / sum(daily.trips_compared) as late_trip_share,
    sum(daily.avg_trip_excess_seconds * daily.trips_compared)
    / sum(daily.trips_compared) as avg_trip_excess_seconds,
    sum(daily.long_gap_share * daily.headway_observations)
    / sum(daily.headway_observations) as long_gap_share,
    sum(daily.headway_adherence_share * daily.headway_observations)
    / sum(daily.headway_observations) as headway_adherence_share,
    sum(daily.bunched_share * daily.headway_observations)
    / sum(daily.headway_observations) as bunched_share,
    sum(daily.trip_excess_seconds_sum)
    / sum(daily.trip_scheduled_seconds_sum) as excess_share_of_scheduled,
    sum(daily.trip_scheduled_seconds_sum)
    / sum(daily.trips_compared) as avg_scheduled_trip_seconds,
    cast(sum(daily.late_trips) as bigint) as late_trips,
    cast(sum(daily.trips_with_long_runs) as bigint) as trips_with_long_runs,
    cast(sum(daily.long_run_excess_seconds_sum) as bigint) as long_run_excess_seconds_sum,
    cast(sum(daily.trips_compared_excl_long_runs) as bigint) as trips_compared_excl_long_runs,
    cast(sum(daily.late_trips_excl_long_runs) as bigint) as late_trips_excl_long_runs,
    sum(daily.late_trips_excl_long_runs)
    / sum(daily.trips_compared_excl_long_runs) as late_trip_share_excl_long_runs,
    sum(daily.trip_excess_seconds_sum_excl_long_runs)
    / sum(daily.trips_compared_excl_long_runs) as avg_trip_excess_seconds_excl_long_runs
from all_days
inner join {{ ref('dim_routes') }} as routes on all_days.route_id = routes.route_id
-- a route whose every day had a planned change keeps its row, with null pooled figures
left join normal_days as daily on all_days.route_id = daily.route_id
group by all
order by routes.display_order
