-- Grain: one row per Commuter Rail pattern branch, direction and stop position on the canonical
-- route patterns (GTFS version active on gtfs_as_of_date()), for drawing the network.
-- branch_route_id names the canonical pattern, from its representative trip id
-- (canonical-CR-Franklin-C2-0 -> CR-Franklin-C2): C1 is the main pattern, C2 a second branch.
-- Stop order from GTFS stop_times of the representative trip; platforms mapped to parent stations.

with as_of as (

    select {{ gtfs_as_of_date() }} as as_of_date

),

patterns as (

    select rp.*
    from {{ ref('stg_gtfs__route_patterns') }} as rp
    cross join as_of
    where
        rp.is_canonical
        and rp.route_id in (select routes.route_id from {{ ref('dim_cr_routes') }} as routes)
        and as_of.as_of_date between rp.valid_from_date and rp.valid_to_date

),

stop_times as (

    select st.*
    from {{ ref('stg_gtfs__cr_stop_times') }} as st
    cross join as_of
    where as_of.as_of_date between st.valid_from_date and st.valid_to_date

),

stops as (

    select s.*
    from {{ ref('stg_gtfs__stops') }} as s
    cross join as_of
    where as_of.as_of_date between s.valid_from_date and s.valid_to_date

),

pattern_stops as (

    select
        patterns.route_id,
        regexp_replace(patterns.representative_trip_id, '^canonical-(.+)-[01]$', '\1') as branch_route_id,
        patterns.direction_id,
        patterns.route_pattern_id,
        patterns.route_pattern_name,
        stop_times.stop_sequence,
        coalesce(platforms.parent_station_id, stop_times.stop_id) as station_id
    from patterns
    inner join stop_times on patterns.representative_trip_id = stop_times.trip_id
    left join stops as platforms on stop_times.stop_id = platforms.stop_id

),

ordered as (

    select
        *,
        row_number() over (partition by branch_route_id, direction_id order by stop_sequence) as stop_order
    from pattern_stops

)

select
    {{ dbt_utils.generate_surrogate_key(['ordered.branch_route_id', 'ordered.direction_id', 'ordered.stop_order']) }}
        as cr_route_stop_key,
    cast(ordered.route_id as varchar) as route_id,
    cast(ordered.branch_route_id as varchar) as branch_route_id,
    cast(ordered.direction_id as integer) as direction_id,
    cast(ordered.route_pattern_name as varchar) as route_pattern_name,
    cast(ordered.route_pattern_id as varchar) as route_pattern_id,
    cast(ordered.stop_order as integer) as stop_order,
    cast(count(*) over (partition by ordered.branch_route_id, ordered.direction_id) as integer)
        as stops_on_pattern,
    cast(ordered.station_id as varchar) as station_id,
    cast(stations.stop_name as varchar) as station_name,
    cast(stations.latitude as double) as latitude,
    cast(stations.longitude as double) as longitude,
    cast(routes.route_color_hex as varchar) as route_color_hex,
    cast((select a.as_of_date from as_of as a) as date) as gtfs_as_of_date
from ordered
left join stops as stations on ordered.station_id = stations.stop_id
left join {{ ref('dim_cr_routes') }} as routes on ordered.route_id = routes.route_id
