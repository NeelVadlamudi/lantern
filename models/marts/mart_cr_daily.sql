-- Grain: one row per Commuter Rail route and service date in the MBTA Commuter Rail reliability
-- file. Route ids come from the file (gtfs_route_id) and match seeds/line_name_map.csv; source
-- rows under several line or branch names for one route are added together.
-- Exact counts, numerators and denominators kept apart:
--   on_time_share  = on_time_trips / counted_trips   (otp_numerator / otp_denominator)
--   cancelled_share = cancelled_trips / counted_trips (the file gives one denominator for both)
-- is_current_route: one of the 13 CR- routes in the current GTFS (dim_cr_routes). CR-Middleborough
-- (ended 2025-03-23) and CapeFlyer stay as their own rows, out of the Commuter Rail totals.
-- estimated_boardings is the MBTA's own estimate (scaled conductor counts) for the line that day,
-- null where the boardings file has no row. Franklin/Foxboro boardings are on CR-Franklin.
-- Commuter Rail never enters train delay or the segment ranking.

with reliability as (

    select
        rel.source_route_id as route_id,
        rel.service_date,
        count(*) as source_rows,
        string_agg(distinct rel.source_line_name, '; ' order by rel.source_line_name) as source_line_names,
        sum(rel.on_time_trips) filter (where rel.peak_offpeak = 'PEAK') as peak_on_time_trips,
        sum(rel.counted_trips) filter (where rel.peak_offpeak = 'PEAK') as peak_counted_trips,
        sum(rel.cancelled_trips) filter (where rel.peak_offpeak = 'PEAK') as peak_cancelled_trips,
        sum(rel.on_time_trips) filter (where rel.peak_offpeak = 'OFF_PEAK') as off_peak_on_time_trips,
        sum(rel.counted_trips) filter (where rel.peak_offpeak = 'OFF_PEAK') as off_peak_counted_trips,
        sum(rel.cancelled_trips) filter (where rel.peak_offpeak = 'OFF_PEAK') as off_peak_cancelled_trips,
        sum(rel.on_time_trips) as on_time_trips,
        sum(rel.counted_trips) as counted_trips,
        sum(rel.cancelled_trips) as cancelled_trips
    from {{ ref('stg_mbta__cr_reliability') }} as rel
    group by rel.source_route_id, rel.service_date

),

boardings as (

    select
        map.route_id,
        board.service_date,
        sum(board.estimated_boardings) as estimated_boardings
    from {{ ref('stg_mbta__cr_boardings') }} as board
    inner join {{ ref('line_name_map') }} as map
        on map.dataset = 'cr_boardings' and board.source_line_name = map.source_name
    group by map.route_id, board.service_date

)

select
    {{ dbt_utils.generate_surrogate_key(['reliability.route_id', 'reliability.service_date']) }} as cr_route_day_key,
    cast(reliability.route_id as varchar) as route_id,
    cast(reliability.service_date as date) as service_date,
    cast(routes.route_id is not null as boolean) as is_current_route,
    cast(reliability.source_rows as bigint) as source_rows,
    cast(reliability.source_line_names as varchar) as source_line_names,
    cast(coalesce(reliability.peak_on_time_trips, 0) as bigint) as peak_on_time_trips,
    cast(coalesce(reliability.peak_counted_trips, 0) as bigint) as peak_counted_trips,
    cast(coalesce(reliability.peak_cancelled_trips, 0) as bigint) as peak_cancelled_trips,
    cast(coalesce(reliability.off_peak_on_time_trips, 0) as bigint) as off_peak_on_time_trips,
    cast(coalesce(reliability.off_peak_counted_trips, 0) as bigint) as off_peak_counted_trips,
    cast(coalesce(reliability.off_peak_cancelled_trips, 0) as bigint) as off_peak_cancelled_trips,
    cast(reliability.on_time_trips as bigint) as on_time_trips,
    cast(reliability.counted_trips as bigint) as counted_trips,
    cast(reliability.cancelled_trips as bigint) as cancelled_trips,
    cast(reliability.on_time_trips / nullif(reliability.counted_trips, 0) as double) as on_time_share,
    cast(reliability.cancelled_trips / nullif(reliability.counted_trips, 0) as double) as cancelled_share,
    cast(boardings.estimated_boardings as double) as estimated_boardings
from reliability
left join {{ ref('dim_cr_routes') }} as routes on reliability.route_id = routes.route_id
left join boardings
    on reliability.route_id = boardings.route_id and reliability.service_date = boardings.service_date
