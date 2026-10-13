-- Worst-line tie fields: the day-paired t (top line minus runner-up, one late-share difference
-- per service date) recomputed from fct_trips, and is_tie_overall / is_tie_weekday follow
-- var('tie_t'). Tolerance 1e-9.
with tile as (
    select tile
    from {{ ref('board_tiles') }}
    where tile_id = 'worst_line'
),

daily as (
    select
        trips.service_date,
        dates.day_type,
        avg(cast(trips.is_late_trip as int)) filter (where trips.route_id = (tile.tile ->> 'value'))
        - avg(cast(trips.is_late_trip as int)) filter (where trips.route_id = (tile.tile ->> 'runner_up_value')) as diff
    from {{ ref('fct_trips') }} as trips
    inner join {{ ref('dim_dates') }} as dates on trips.service_date = dates.date_day
    cross join tile
    inner join {{ ref('mart_planned_change_line_days') }} as planned
        on trips.route_id = planned.route_id and trips.service_date = planned.service_date
    where trips.compared_segments > 0 and trips.is_matched_trip and not planned.is_planned_change
    group by trips.service_date, dates.day_type
),

recomputed as (
    select
        avg(diff) / (stddev_samp(diff) / sqrt(count(diff))) as paired_t,
        avg(diff) filter (where day_type = 'weekday')
        / (
            stddev_samp(diff) filter (where day_type = 'weekday')
            / sqrt(count(diff) filter (where day_type = 'weekday'))
        ) as weekday_paired_t
    from daily
)

select recomputed.*
from recomputed
cross join tile
where
    abs(recomputed.paired_t - cast(tile.tile ->> 'paired_t' as double)) > 1e-9
    or abs(recomputed.weekday_paired_t - cast(tile.tile ->> 'weekday_paired_t' as double)) > 1e-9
    or cast(tile.tile ->> 'is_tie_overall' as boolean) != (abs(recomputed.paired_t) < {{ var('tie_t') }})
    or cast(tile.tile ->> 'is_tie_weekday' as boolean) != (abs(recomputed.weekday_paired_t) < {{ var('tie_t') }})
