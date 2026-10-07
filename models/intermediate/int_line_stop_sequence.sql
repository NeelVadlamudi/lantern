-- Grain: one row per route, branch, direction and stop position on the canonical route pattern
-- in the GTFS version active on gtfs_as_of_date().
-- Stop order comes from the representative trip of each canonical pattern (GTFS stop_times),
-- mapped from platform stop ids to parent stations. Red Line has two canonical patterns per
-- direction; they are labelled Red-A (Ashmont) and Red-B (Braintree) to match LAMP's branch ids.

with as_of as (

    select {{ gtfs_as_of_date() }} as as_of_date

),

patterns as (

    select rp.*
    from {{ ref('stg_gtfs__route_patterns') }} as rp
    cross join as_of
    where rp.is_canonical
        and rp.route_id in (select ld.route_id from {{ ref('line_display') }} as ld)
        and as_of.as_of_date between rp.valid_from_date and rp.valid_to_date

),

stop_times as (

    select st.*
    from {{ ref('stg_gtfs__stop_times') }} as st
    cross join as_of
    where as_of.as_of_date between st.valid_from_date and st.valid_to_date

),

platforms as (

    select
        s.stop_id,
        s.parent_station_id
    from {{ ref('stg_gtfs__stops') }} as s
    cross join as_of
    where as_of.as_of_date between s.valid_from_date and s.valid_to_date

),

pattern_stops as (

    select
        patterns.route_pattern_id,
        patterns.route_id,
        patterns.direction_id,
        patterns.route_pattern_name,
        stop_times.stop_sequence,
        coalesce(platforms.parent_station_id, stop_times.stop_id) as station_id
    from patterns
    inner join stop_times
        on patterns.representative_trip_id = stop_times.trip_id
    left join platforms
        on stop_times.stop_id = platforms.stop_id

),

branched as (

    select
        pattern_stops.*,
        case
            when pattern_stops.route_id = 'Red'
                then coalesce(
                        max(red.branch_route_id) over (partition by pattern_stops.route_pattern_id),
                        'Red'
                    )
            else pattern_stops.route_id
        end as branch_route_id
    from pattern_stops
    left join {{ ref('red_line_branches') }} as red
        on pattern_stops.station_id = red.branch_terminal_station_id

)

select
    {{ dbt_utils.generate_surrogate_key(['branch_route_id', 'direction_id', 'stop_sequence']) }}
        as line_stop_key,
    route_id,
    branch_route_id,
    direction_id,
    route_pattern_id,
    route_pattern_name,
    cast(row_number() over (
        partition by branch_route_id, direction_id order by stop_sequence
    ) as integer) as stop_order,
    station_id,
    (select a.as_of_date from as_of as a) as gtfs_as_of_date
from branched
