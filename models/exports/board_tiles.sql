{{ config(materialized='table') }}
-- Board headline tiles: one row per tile, in display order. Measured train delay comes first:
-- recorded train run time over the schedule on an average weekday (mart_train_delay_summary),
-- positive (late time only) and net, with the all-days values next to it. Rider time lost is
-- second and is an estimate (people entering stations, riders assumed to arrive at random).
-- Every tile has `sentence`: one plain sentence filled from the tile's own values. Time values
-- also carry exact seconds (value_seconds) and a format_duration label (value_label). The late, excess and long-gap
-- tiles are over all days (weekdays, weekends and holidays); value_weekday carries the same
-- measure over weekdays only. The rider tile is weekday by definition. `tile` is the JSON object the
-- board reads (board_data.json tiles); value_number / value_text repeat the headline value
-- so the tests in tests/kpi/ can recompute it from the facts and compare.
--   late / excess / long-gap tiles: pooled from mart_line_daily_reliability, all days;
--     value_weekday from the weekday rows
--   rider tile: summed over mart_station_overview (gated stations only)
--   worst line: board_line_totals, ties broken by display order
--   freshness: last service date in dim_dates against today's date in Boston
--   train delay: mart_train_delay_summary, weekday and all_days rows
--   rider time lost: mart_rider_time_lost_daily, averaged over weekdays (and all days) with a
--     rider weight; *_with_gaps adds the gaps over 1 hour that count as passenger waits

with

system_wide as (
    select
        sum(late_trip_share * trips_compared) / sum(trips_compared) as late_trip_share,
        sum(avg_trip_excess_seconds * trips_compared) / sum(trips_compared) as avg_trip_excess_seconds,
        sum(long_gap_share * headway_observations) / sum(headway_observations) as long_gap_share,
        cast(sum(trips_compared) as bigint) as trips_compared,
        cast(sum(headway_observations) as bigint) as headway_observations,
        sum(trip_excess_seconds_sum) / sum(trip_scheduled_seconds_sum) as excess_share_of_scheduled,
        sum(trip_scheduled_seconds_sum) / sum(trips_compared) as avg_scheduled_trip_seconds,
        cast(sum(late_trips) as bigint) as late_trips,
        cast(sum(trips_with_long_runs) as bigint) as trips_with_long_runs,
        cast(sum(long_run_comparisons) as bigint) as long_run_comparisons,
        cast(sum(long_run_excess_seconds_sum) as bigint) as long_run_excess_seconds_sum,
        cast(sum(trips_compared_excl_long_runs) as bigint) as trips_compared_excl_long_runs,
        cast(sum(late_trips_excl_long_runs) as bigint) as late_trips_excl_long_runs,
        sum(late_trips_excl_long_runs) / sum(trips_compared_excl_long_runs) as late_trip_share_excl_long_runs,
        sum(trip_excess_seconds_sum_excl_long_runs) / sum(trips_compared_excl_long_runs)
            as avg_trip_excess_seconds_excl_long_runs
    from {{ ref('mart_line_daily_reliability') }}
),

-- the same pooled figures over weekdays only (secondary values for the board's day toggle)
weekday as (
    select
        sum(late_trip_share * trips_compared) / sum(trips_compared) as late_trip_share,
        sum(avg_trip_excess_seconds * trips_compared) / sum(trips_compared) as avg_trip_excess_seconds,
        sum(long_gap_share * headway_observations) / sum(headway_observations) as long_gap_share,
        sum(trip_excess_seconds_sum) / sum(trip_scheduled_seconds_sum) as excess_share_of_scheduled,
        cast(sum(late_trips) as bigint) as late_trips,
        cast(sum(trips_compared) as bigint) as trips_compared,
        sum(late_trips_excl_long_runs) / sum(trips_compared_excl_long_runs) as late_trip_share_excl_long_runs,
        sum(trip_excess_seconds_sum_excl_long_runs) / sum(trips_compared_excl_long_runs)
            as avg_trip_excess_seconds_excl_long_runs
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

train_delay as (
    select
        summary_weekday.service_dates as weekdays,
        summary_weekday.avg_daily_positive_excess_seconds as weekday_seconds,
        summary_weekday.avg_daily_net_excess_seconds as weekday_net_seconds,
        summary_weekday.avg_daily_runs as weekday_runs,
        summary_weekday.positive_excess_seconds_per_run as weekday_per_run_seconds,
        summary_weekday.net_excess_seconds_per_run as weekday_net_per_run_seconds,
        summary_weekday.long_runs / summary_weekday.service_dates as weekday_long_runs,
        summary_weekday.avg_daily_long_run_positive_excess_seconds as weekday_long_run_seconds,
        summary_weekday.avg_daily_long_run_net_excess_seconds as weekday_long_run_net_seconds,
        summary_weekday.avg_daily_positive_excess_seconds_excl_long_runs as weekday_excl_long_runs_seconds,
        summary_weekday.avg_daily_net_excess_seconds_excl_long_runs as weekday_excl_long_runs_net_seconds,
        summary_weekday.avg_daily_terminal_hold_seconds as weekday_terminal_hold_seconds,
        summary_weekday.avg_daily_terminal_hold_negative_seconds as weekday_terminal_hold_negative_seconds,
        summary_weekday.avg_daily_terminal_hold_positive_seconds as weekday_terminal_hold_positive_seconds,
        summary_weekday.terminal_hold_negative_runs as weekday_terminal_hold_negative_runs,
        summary_all_days.service_dates,
        summary_all_days.avg_daily_positive_excess_seconds as all_days_seconds,
        summary_all_days.avg_daily_net_excess_seconds as all_days_net_seconds,
        summary_all_days.avg_daily_runs as all_days_runs,
        summary_all_days.positive_excess_seconds_per_run as all_days_per_run_seconds,
        summary_all_days.net_excess_seconds_per_run as all_days_net_per_run_seconds
    from {{ ref('mart_train_delay_summary') }} as summary_weekday
    cross join {{ ref('mart_train_delay_summary') }} as summary_all_days
    where summary_weekday.day_basis = 'weekday' and summary_all_days.day_basis = 'all_days'
),

rider_time as (
    select
        avg(rider_seconds_lost) filter (where day_type = 'weekday') as weekday_seconds,
        avg(rider_seconds_lost_with_gaps) filter (where day_type = 'weekday') as weekday_with_gaps_seconds,
        avg(rider_wait_seconds_lost_with_gaps) filter (where day_type = 'weekday') as weekday_wait_with_gaps_seconds,
        avg(rider_seconds_lost_with_gaps) as all_days_with_gaps_seconds,
        avg(rider_wait_seconds_lost) filter (where day_type = 'weekday') as weekday_wait_seconds,
        avg(rider_ride_seconds_lost) filter (where day_type = 'weekday') as weekday_ride_seconds,
        sum(rider_seconds_lost) filter (where day_type = 'weekday')
        / sum(gated_entries) filter (where day_type = 'weekday') as weekday_seconds_per_entry,
        avg(gated_entries) filter (where day_type = 'weekday') as weekday_gated_entries,
        avg(gated_entries_no_trains) filter (where day_type = 'weekday') as weekday_gated_entries_no_trains,
        avg(gated_entries_all_cells) filter (where day_type = 'weekday') as weekday_gated_entries_all_cells,
        avg(cells_no_trains) filter (where day_type = 'weekday') as weekday_cells_no_trains,
        avg(rider_seconds_lost) as all_days_seconds,
        sum(rider_seconds_lost) / sum(gated_entries) as all_days_seconds_per_entry,
        count(*) filter (where day_type = 'weekday') as weekdays,
        count(*) as service_dates
    from {{ ref('mart_rider_time_lost_daily') }}
    where has_rider_data
),

freshness as (
    select
        max(date_day) as last_service_date,
        cast(timezone('America/New_York', now()) as date) - max(date_day) as days_behind
    from {{ ref('dim_dates') }}
),

tiles as (
    select
        0 as sort_order,
        'train_delay_weekday' as tile_id,
        train_delay.weekday_seconds as value_number,
        train_delay.weekday_seconds as value_weekday,
        {{ format_duration('train_delay.weekday_seconds') }} as value_text,
        json_object(
            'id', 'train_delay_weekday',
            'label', 'Train time over schedule',
            'day_basis', 'weekday',
            'is_estimate', false,
            'value', train_delay.weekday_seconds,
            'value_seconds', train_delay.weekday_seconds,
            'value_label', {{ format_duration('train_delay.weekday_seconds') }},
            'display', {{ format_duration('train_delay.weekday_seconds') }},
            'net_seconds', train_delay.weekday_net_seconds,
            'net_label', {{ format_duration('train_delay.weekday_net_seconds') }},
            'runs', train_delay.weekday_runs,
            'weekdays', train_delay.weekdays,
            'per_run_seconds', train_delay.weekday_per_run_seconds,
            'per_run_label', {{ format_duration('train_delay.weekday_per_run_seconds') }},
            'net_per_run_seconds', train_delay.weekday_net_per_run_seconds,
            'net_per_run_label', {{ format_duration('train_delay.weekday_net_per_run_seconds') }},
            'long_runs', train_delay.weekday_long_runs,
            'long_run_seconds', train_delay.weekday_long_run_seconds,
            'long_run_label', {{ format_duration('train_delay.weekday_long_run_seconds') }},
            'long_run_net_seconds', train_delay.weekday_long_run_net_seconds,
            'excl_long_runs_seconds', train_delay.weekday_excl_long_runs_seconds,
            'excl_long_runs_label', {{ format_duration('train_delay.weekday_excl_long_runs_seconds') }},
            'excl_long_runs_net_seconds', train_delay.weekday_excl_long_runs_net_seconds,
            'excl_long_runs_net_label', {{ format_duration('train_delay.weekday_excl_long_runs_net_seconds') }},
            'terminal_hold_seconds', train_delay.weekday_terminal_hold_seconds,
            'terminal_hold_label', {{ format_duration('train_delay.weekday_terminal_hold_seconds') }},
            'terminal_hold_negative_seconds', train_delay.weekday_terminal_hold_negative_seconds,
            'terminal_hold_positive_seconds', train_delay.weekday_terminal_hold_positive_seconds,
            'terminal_hold_negative_runs', train_delay.weekday_terminal_hold_negative_runs,
            'all_days_value_seconds', train_delay.all_days_seconds,
            'all_days_value_label', {{ format_duration('train_delay.all_days_seconds') }},
            'all_days_net_seconds', train_delay.all_days_net_seconds,
            'all_days_net_label', {{ format_duration('train_delay.all_days_net_seconds') }},
            'all_days_runs', train_delay.all_days_runs,
            'all_days_per_run_seconds', train_delay.all_days_per_run_seconds,
            'all_days_per_run_label', {{ format_duration('train_delay.all_days_per_run_seconds') }},
            'all_days_net_per_run_seconds', train_delay.all_days_net_per_run_seconds,
            'all_days_net_per_run_label', {{ format_duration('train_delay.all_days_net_per_run_seconds') }},
            'service_dates', train_delay.service_dates,
            'sentence', 'On an average weekday, each train run between two stops took '
            || {{ format_duration('train_delay.weekday_per_run_seconds') }}
            || ' longer than scheduled, counting late time only ('
            || {{ format_duration('train_delay.weekday_net_per_run_seconds') }} || ' net of early runs).',
            'sentence_total', 'Across about ' || format('{:,.0f}', train_delay.weekday_runs)
            || ' runs a weekday, that adds up to '
            || {{ format_duration('train_delay.weekday_seconds') }} || ' of train time over schedule ('
            || {{ format_duration('train_delay.weekday_net_seconds') }} || ' net).',
            'explainer', 'Measured from recorded train runs: for every run between two stops, the recorded'
            || ' time from arrival at one stop to arrival at the next (from departure on a train''s first'
            || ' stop and when it leaves a terminal) minus scheduled time, summed over the runs of each weekday and'
            || ' averaged over ' || train_delay.weekdays || ' weekdays. Late time only counts runs slower'
            || ' than scheduled; net lets faster runs offset slower ones. Runs over 30 minutes are'
            || ' included (' || {{ format_duration('train_delay.weekday_long_run_seconds') }}
            || ' a weekday). Time trains spend on terminal platforms before leaving ('
            || {{ format_duration('train_delay.weekday_terminal_hold_seconds') }}
            || ' a weekday) is shown separately and not counted. Over all days the average is '
            || {{ format_duration('train_delay.all_days_seconds') }} || ' a day.'
        ) as tile
    from train_delay

    union all

    select
        1 as sort_order,
        'rider_time_lost' as tile_id,
        rider_time.weekday_seconds as value_number,
        rider_time.weekday_seconds as value_weekday,
        {{ format_duration('rider_time.weekday_seconds') }} as value_text,
        json_object(
            'id', 'rider_time_lost',
            'label', 'Rider time lost beyond the schedule (estimate)',
            'day_basis', 'weekday',
            'is_estimate', true,
            'value', rider_time.weekday_seconds,
            'value_seconds', rider_time.weekday_seconds,
            'value_label', {{ format_duration('rider_time.weekday_seconds') }},
            'display', {{ format_duration('rider_time.weekday_seconds') }},
            'wait_seconds', rider_time.weekday_wait_seconds,
            'wait_label', {{ format_duration('rider_time.weekday_wait_seconds') }},
            'ride_seconds', rider_time.weekday_ride_seconds,
            'ride_label', {{ format_duration('rider_time.weekday_ride_seconds') }},
            'per_entry_seconds', rider_time.weekday_seconds_per_entry,
            'per_entry_label', {{ format_duration('rider_time.weekday_seconds_per_entry') }},
            'gated_entries', rider_time.weekday_gated_entries,
            'gated_entries_no_trains', rider_time.weekday_gated_entries_no_trains,
            'gated_entries_all_cells', rider_time.weekday_gated_entries_all_cells,
            'cells_no_trains', rider_time.weekday_cells_no_trains,
            'weekdays', rider_time.weekdays,
            'all_days_value_seconds', rider_time.all_days_seconds,
            'all_days_value_label', {{ format_duration('rider_time.all_days_seconds') }},
            'all_days_per_entry_seconds', rider_time.all_days_seconds_per_entry,
            'all_days_per_entry_label', {{ format_duration('rider_time.all_days_seconds_per_entry') }},
            'service_dates', rider_time.service_dates,
            'with_gaps_seconds', rider_time.weekday_with_gaps_seconds,
            'with_gaps_label', {{ format_duration('rider_time.weekday_with_gaps_seconds') }},
            'wait_with_gaps_seconds', rider_time.weekday_wait_with_gaps_seconds,
            'wait_with_gaps_label', {{ format_duration('rider_time.weekday_wait_with_gaps_seconds') }},
            'all_days_with_gaps_seconds', rider_time.all_days_with_gaps_seconds,
            'all_days_with_gaps_label', {{ format_duration('rider_time.all_days_with_gaps_seconds') }},
            'sentence', 'Riders lost an estimated ' || {{ format_duration('rider_time.weekday_seconds') }}
            || ' waiting and riding beyond the schedule on an average weekday.',
            'sentence_with_gaps', 'Counting the gaps over 1 hour as waits too, the estimate is '
            || {{ format_duration('rider_time.weekday_with_gaps_seconds') }} || ' a weekday.',
            'explainer', 'Estimate based on people entering stations, assuming riders arrive at random'
            || ' times. Summed over gated stations, lines and times of day: gate entries times'
            || ' (expected wait with the actual gaps between trains minus expected wait with the scheduled'
            || ' gaps, plus extra run time on the next segment). That is about '
            || {{ format_duration('rider_time.weekday_seconds_per_entry') }} || ' per entry; '
            || {{ format_duration('rider_time.weekday_wait_seconds') }} || ' of the total is waiting and '
            || {{ format_duration('rider_time.weekday_ride_seconds') }} || ' is riding. Over all days the'
            || ' average is ' || {{ format_duration('rider_time.all_days_seconds') }} || ' a day. Gaps'
            || ' over 1 hour are left out of the wait here; with them it is '
            || {{ format_duration('rider_time.weekday_with_gaps_seconds') }} || ' a weekday.'
        ) as tile
    from rider_time

    union all

    select
        2 as sort_order,
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
            'late_trips', system_wide.late_trips,
            'trips_compared', system_wide.trips_compared,
            'late_trips_weekday', weekday.late_trips,
            'trips_compared_weekday', weekday.trips_compared,
            'trips_with_long_runs', system_wide.trips_with_long_runs,
            'value_excl_long_runs', system_wide.late_trip_share_excl_long_runs,
            'late_trips_excl_long_runs', system_wide.late_trips_excl_long_runs,
            'trips_compared_excl_long_runs', system_wide.trips_compared_excl_long_runs,
            'value_weekday_excl_long_runs', weekday.late_trip_share_excl_long_runs,
            'sentence', 'Over all days, ' || printf('%.1f%%', 100 * system_wide.late_trip_share)
            || ' of train runs took more than 5 minutes longer than scheduled.',
            'explainer', 'Of ' || format('{:,}', system_wide.trips_compared)
            || ' subway train runs compared to the schedule on all days (weekdays, weekends and'
            || ' holidays), this share took more than 5 minutes longer than scheduled between their'
            || ' first and last compared stops. Stop-to-stop runs over 30 minutes are included ('
            || format('{:,}', system_wide.trips_with_long_runs) || ' runs had one); without them the'
            || ' share is ' || printf('%.1f%%', 100 * system_wide.late_trip_share_excl_long_runs) || '.'
        ) as tile
    from system_wide
    cross join weekday

    union all

    select
        3 as sort_order,
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
            'value_seconds', system_wide.avg_trip_excess_seconds,
            'value_label', {{ format_duration('system_wide.avg_trip_excess_seconds') }},
            'value_weekday_seconds', weekday.avg_trip_excess_seconds,
            'value_weekday_label', {{ format_duration('weekday.avg_trip_excess_seconds') }},
            'long_run_comparisons', system_wide.long_run_comparisons,
            'long_run_excess_seconds_sum', system_wide.long_run_excess_seconds_sum,
            'value_excl_long_runs_seconds', system_wide.avg_trip_excess_seconds_excl_long_runs,
            'value_excl_long_runs_label', {{ format_duration('system_wide.avg_trip_excess_seconds_excl_long_runs') }},
            'value_weekday_excl_long_runs_seconds', weekday.avg_trip_excess_seconds_excl_long_runs,
            'value_weekday_excl_long_runs_label',
            {{ format_duration('weekday.avg_trip_excess_seconds_excl_long_runs') }},
            'sentence', 'Over all days, the average train run took '
            || {{ format_duration('abs(system_wide.avg_trip_excess_seconds)') }}
            || case when system_wide.avg_trip_excess_seconds < 0 then ' less' else ' longer' end
            || ' than scheduled.',
            'explainer', 'Per train run on all days (weekdays, weekends and holidays), actual minus'
            || ' scheduled time summed over its compared stops, averaged over all compared runs. That is '
            || printf('%.1f%%', 100 * system_wide.excess_share_of_scheduled) || ' of an average '
            || printf('%.0f', system_wide.avg_scheduled_trip_seconds / 60)
            || '-minute scheduled run. Small on average; the late tail is what riders feel. Stop-to-stop'
            || ' runs over 30 minutes are included; without them the average is '
            || {{ format_duration('system_wide.avg_trip_excess_seconds_excl_long_runs') }} || '.'
        ) as tile
    from system_wide
    cross join weekday

    union all

    select
        4 as sort_order,
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
            'sentence', 'Over all days, ' || printf('%.1f%%', 100 * system_wide.long_gap_share)
            || ' of train departures came after a gap more than 1.5 times the scheduled one.',
            'explainer', 'Share of ' || format('{:,}', system_wide.headway_observations)
            || ' train departures from stations on all days (weekdays, weekends and holidays) where'
            || ' the gap since the previous train on the line was more than 1.5 times the scheduled gap.'
        ) as tile
    from system_wide
    cross join weekday

    union all

    select
        5 as sort_order,
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
            'sentence', 'On an average weekday, about ' || format('{:,.0f}', weekday_entries_in_long_gaps)
            || ' fare-gate entries happen while trains are running a long gap.',
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
        6 as sort_order,
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
            'sentence', worst_late.display_name || ' had the highest share of trips 5+ minutes late over all'
            || ' days (' || printf('%.1f%%', 100 * worst_late.late_trip_share) || ').',
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
        7 as sort_order,
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
            'sentence', 'Data runs through ' || strftime(last_service_date, '%A, %B %-d, %Y') || '.',
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
