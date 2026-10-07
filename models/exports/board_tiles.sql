{{ config(materialized='table') }}
-- Board headline tiles: one row per tile, in display order. The late, excess and long-gap
-- tiles are over all days (weekdays, weekends and holidays); value_weekday carries the same
-- measure over weekdays only. The rider tile is weekday by definition. `tile` is the JSON object the
-- board reads (board_data.json tiles); value_number / value_text repeat the headline value
-- so the tests in tests/kpi/ can recompute it from the facts and compare.
--   late / excess / long-gap tiles: pooled from mart_line_daily_reliability, all days;
--     value_weekday from the weekday rows
--   rider tile: summed over mart_station_overview (gated stations only)
--   worst line: board_line_totals, ties broken by display order
--   freshness: last service date in dim_dates against today's date in Boston

with

system_wide as (
    select
        sum(late_trip_share * trips_compared) / sum(trips_compared) as late_trip_share,
        sum(avg_trip_excess_seconds * trips_compared) / sum(trips_compared) as avg_trip_excess_seconds,
        sum(long_gap_share * headway_observations) / sum(headway_observations) as long_gap_share,
        cast(sum(trips_compared) as bigint) as trips_compared,
        cast(sum(headway_observations) as bigint) as headway_observations,
        sum(trip_excess_seconds_sum) / sum(trip_scheduled_seconds_sum) as excess_share_of_scheduled,
        sum(trip_scheduled_seconds_sum) / sum(trips_compared) as avg_scheduled_trip_seconds
    from {{ ref('mart_line_daily_reliability') }}
),

-- the same pooled figures over weekdays only (secondary values for the board's day toggle)
weekday as (
    select
        sum(late_trip_share * trips_compared) / sum(trips_compared) as late_trip_share,
        sum(avg_trip_excess_seconds * trips_compared) / sum(trips_compared) as avg_trip_excess_seconds,
        sum(long_gap_share * headway_observations) / sum(headway_observations) as long_gap_share,
        sum(trip_excess_seconds_sum) / sum(trip_scheduled_seconds_sum) as excess_share_of_scheduled
    from {{ ref('mart_line_daily_reliability') }}
    where day_type = 'weekday'
),

exposure as (
    select
        sum(weekday_entries_in_long_gaps) as weekday_entries_in_long_gaps,
        sum(weekday_gated_entries) as weekday_gated_entries,
        sum(est_daily_entries_in_long_gaps) as all_days_entries_in_long_gaps,
        count(*) filter (where has_gated_entries) as stations_with_gates
    from {{ ref('mart_station_overview') }}
),

worst_late as (
    select * from {{ ref('board_line_totals') }}
    order by late_trip_share desc, display_order asc
    limit 1
),

worst_gap as (
    select * from {{ ref('board_line_totals') }}
    order by long_gap_share desc, display_order asc
    limit 1
),

worst_relative as (
    select * from {{ ref('board_line_totals') }}
    order by excess_share_of_scheduled desc, display_order asc
    limit 1
),

freshness as (
    select
        max(date_day) as last_service_date,
        cast(timezone('America/New_York', now()) as date) - max(date_day) as days_behind
    from {{ ref('dim_dates') }}
),

tiles as (
    select
        1 as sort_order,
        'late_trip_share' as tile_id,
        {{ board_round('system_wide.late_trip_share', 4) }} as value_number,
        {{ board_round('weekday.late_trip_share', 4) }} as value_weekday,
        null as value_text,
        json_object(
            'id', 'late_trip_share',
            'label', 'Trips 5+ min behind schedule',
            'day_basis', 'all_days',
            'value', {{ board_round('system_wide.late_trip_share', 4) }},
            'display', printf('%.1f%%', 100 * system_wide.late_trip_share),
            'value_weekday', {{ board_round('weekday.late_trip_share', 4) }},
            'display_weekday', printf('%.1f%%', 100 * weekday.late_trip_share),
            'explainer', 'Of ' || format('{:,}', system_wide.trips_compared)
            || ' subway train runs compared to the schedule on all days (weekdays, weekends and'
            || ' holidays), this share took more than 5 minutes longer than scheduled between their'
            || ' first and last compared stops.'
        ) as tile
    from system_wide
    cross join weekday

    union all

    select
        2 as sort_order,
        'avg_trip_excess_seconds' as tile_id,
        {{ board_round('system_wide.avg_trip_excess_seconds', 1) }} as value_number,
        {{ board_round('weekday.avg_trip_excess_seconds', 1) }} as value_weekday,
        null as value_text,
        json_object(
            'id', 'avg_trip_excess_seconds',
            'label', 'Average time over schedule per trip',
            'day_basis', 'all_days',
            'value', {{ board_round('system_wide.avg_trip_excess_seconds', 1) }},
            'display', printf('%+.0f s', system_wide.avg_trip_excess_seconds),
            'share_of_scheduled', {{ board_round('system_wide.excess_share_of_scheduled', 4) }},
            'value_weekday', {{ board_round('weekday.avg_trip_excess_seconds', 1) }},
            'display_weekday', printf('%+.0f s', weekday.avg_trip_excess_seconds),
            'share_of_scheduled_weekday', {{ board_round('weekday.excess_share_of_scheduled', 4) }},
            'explainer', 'Per train run on all days (weekdays, weekends and holidays), actual minus'
            || ' scheduled time summed over its compared stops, averaged over all compared runs. That is '
            || printf('%.1f%%', 100 * system_wide.excess_share_of_scheduled) || ' of an average '
            || printf('%.0f', system_wide.avg_scheduled_trip_seconds / 60)
            || '-minute scheduled run. Small on average; the late tail is what riders feel.'
        ) as tile
    from system_wide
    cross join weekday

    union all

    select
        3 as sort_order,
        'long_gap_share' as tile_id,
        {{ board_round('system_wide.long_gap_share', 4) }} as value_number,
        {{ board_round('weekday.long_gap_share', 4) }} as value_weekday,
        null as value_text,
        json_object(
            'id', 'long_gap_share',
            'label', 'Waits over 1.5x the scheduled gap',
            'day_basis', 'all_days',
            'value', {{ board_round('system_wide.long_gap_share', 4) }},
            'display', printf('%.1f%%', 100 * system_wide.long_gap_share),
            'value_weekday', {{ board_round('weekday.long_gap_share', 4) }},
            'display_weekday', printf('%.1f%%', 100 * weekday.long_gap_share),
            'explainer', 'Share of ' || format('{:,}', system_wide.headway_observations)
            || ' train departures from stations on all days (weekdays, weekends and holidays) where'
            || ' the gap since the previous train on the line was more than 1.5 times the scheduled gap.'
        ) as tile
    from system_wide
    cross join weekday

    union all

    select
        4 as sort_order,
        'weekday_entries_in_long_gaps' as tile_id,
        round_even(weekday_entries_in_long_gaps, 0) as value_number,
        null as value_weekday,
        null as value_text,
        json_object(
            'id', 'weekday_entries_in_long_gaps',
            'label', 'Weekday gate entries during long gaps',
            'day_basis', 'weekday',
            'value', cast(round_even(weekday_entries_in_long_gaps, 0) as bigint),
            'display', printf('~%.1fk', weekday_entries_in_long_gaps / 1000),
            'share_of_entries', {{ board_round('weekday_entries_in_long_gaps / weekday_gated_entries', 4) }},
            'weekday_gated_entries', cast(round_even(weekday_gated_entries, 0) as bigint),
            'all_days_value', cast(round_even(all_days_entries_in_long_gaps, 0) as bigint),
            'explainer', 'On an average weekday, about ' || format('{:,.0f}', weekday_entries_in_long_gaps)
            || ' of ' || format('{:,.0f}', weekday_gated_entries) || ' fare-gate entries ('
            || printf('%.1f%%', 100 * weekday_entries_in_long_gaps / weekday_gated_entries)
            || ') are made at a station, line and time of day while trains are running a long gap,'
            || ' estimated from the long-gap share. Entries, not people; only the '
            || stations_with_gates || ' gated stations are counted.'
        ) as tile
    from exposure

    union all

    select
        5 as sort_order,
        'worst_line' as tile_id,
        {{ board_round('worst_late.late_trip_share', 4) }} as value_number,
        null as value_weekday,
        worst_late.route_id as value_text,
        json_object(
            'id', 'worst_line',
            'label', 'Line most often behind schedule',
            'day_basis', 'all_days',
            'value', worst_late.route_id,
            'display', worst_late.display_name,
            'metric_value', {{ board_round('worst_late.late_trip_share', 4) }},
            'metric_display', printf('%.1f%%', 100 * worst_late.late_trip_share),
            'explainer', 'Over all days, ' || worst_late.display_name
            || ' had the highest share of trips 5+ minutes late ('
            || printf('%.1f%%', 100 * worst_late.late_trip_share)
            || '). Relative to scheduled run time, ' || worst_relative.display_name || ' ran furthest over ('
            || printf('%.1f%%', 100 * worst_relative.excess_share_of_scheduled) || '). '
            || worst_gap.display_name || ' had the most long gaps ('
            || printf('%.1f%%', 100 * worst_gap.long_gap_share) || ').'
        ) as tile
    from worst_late
    cross join worst_relative
    cross join worst_gap

    union all

    select
        6 as sort_order,
        'freshness' as tile_id,
        days_behind as value_number,
        null as value_weekday,
        strftime(last_service_date, '%Y-%m-%d') as value_text,
        json_object(
            'id', 'freshness',
            'label', 'Latest service day loaded',
            'value', strftime(last_service_date, '%Y-%m-%d'),
            'display', strftime(last_service_date, '%b %-d, %Y'),
            'days_behind', days_behind,
            'explainer', 'MBTA publishes each day''s subway data the next day. Data here runs through '
            || strftime(last_service_date, '%A, %B %-d')
            || case when days_behind = 1 then ' (yesterday).' else ' (' || days_behind || ' days ago).' end
        ) as tile
    from freshness
)

select
    sort_order,
    tile_id,
    cast(value_number as double) as value_number,
    cast(value_weekday as double) as value_weekday,
    cast(value_text as varchar) as value_text,
    tile
from tiles
order by sort_order
