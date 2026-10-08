-- The train delay tile (tiles[0], average weekday) recomputed from fct_trip_stop_events and the
-- LAMP timestamps, not from the marts: every run after a trip's first observed stop with actual
-- and scheduled run time both positive; run = actual, minus the terminal platform hold when a
-- run leaving a branch terminal is not the trip's first observed segment (LAMP move time here
-- minus arrival at the terminal); positive = sum of max(run - scheduled, 0), net = sum of
-- (run - scheduled), per weekday and per run. Also checks that nothing is lost on the way: the
-- summary rows add up to the daily rows, runs_observed = compared + the four not-compared
-- counts, and net = actual sum - hold inside actual - scheduled sum. Exact integer sums;
-- averages to 1e-9 relative.
with terminals as (
    select
        branch_route_id,
        direction_id,
        arg_min(station_id, stop_order) as first_station_id
    from {{ ref('int_line_stop_sequence') }}
    group by branch_route_id, direction_id
),

events as (
    select
        events.*,
        dates.day_type,
        epoch(lamp.moved_at) as moved_epoch,
        row_number() over trip_order as stop_position,
        lag(events.station_id) over trip_order as previous_station_id,
        lag(epoch(lamp.stopped_at)) over trip_order as previous_stopped_epoch
    from {{ ref('fct_trip_stop_events') }} as events
    inner join {{ ref('dim_dates') }} as dates on events.date_key = dates.date_key
    left join {{ ref('stg_lamp__subway_trip_stops') }} as lamp
        on events.trip_stop_event_key = lamp.trip_stop_event_key
    window trip_order as (
        partition by events.trip_key
        order by events.stop_sequence, events.event_local_at, events.trip_stop_event_key
    )
),

compared as (
    select
        events.day_type,
        events.date_key,
        events.actual_run_seconds - coalesce(
            case
                when events.stop_position > 2 and events.previous_station_id = terminals.first_station_id
                    then events.moved_epoch - events.previous_stopped_epoch
            end,
            0
        ) - events.scheduled_run_seconds as excess
    from events
    left join terminals
        on events.branch_route_id = terminals.branch_route_id and events.direction_id = terminals.direction_id
    where events.stop_position > 1 and events.actual_run_seconds > 0 and events.scheduled_run_seconds > 0
),

fact as (
    select
        sum(greatest(excess, 0)) / count(distinct date_key) as weekday_positive,
        sum(excess) / count(distinct date_key) as weekday_net,
        sum(greatest(excess, 0)) / count(*) as per_run_positive,
        sum(excess) / count(*) as per_run_net
    from compared
    where day_type = 'weekday'
),

tile as (
    select
        tiles.value_number,
        tiles.tile,
        (select payload.tiles -> 0 ->> 'id' from {{ ref('board_payload') }} as payload) as first_tile_id
    from {{ ref('board_tiles') }} as tiles
    where tiles.tile_id = 'train_delay_weekday'
),

tile_check as (
    select 'tile vs fact' as check_name
    from fact
    left join tile on true
    where
        tile.value_number is null
        or abs(tile.value_number - fact.weekday_positive) > 1e-9 * abs(fact.weekday_positive)
        or abs(cast(tile.tile ->> 'net_seconds' as double) - fact.weekday_net)
        > 1e-9 * greatest(abs(fact.weekday_net), 1)
        or abs(cast(tile.tile ->> 'per_run_seconds' as double) - fact.per_run_positive)
        > 1e-9 * abs(fact.per_run_positive)
        or abs(cast(tile.tile ->> 'net_per_run_seconds' as double) - fact.per_run_net)
        > 1e-9 * greatest(abs(fact.per_run_net), 1)
        or (tile.tile ->> 'value_label') != {{ format_duration('tile.value_number') }}
        or tile.first_tile_id != 'train_delay_weekday'
),

daily_check as (
    select 'daily counts add up' as check_name
    from {{ ref('mart_train_delay_daily') }}
    where
        runs_observed != runs_compared + runs_actual_missing + runs_scheduled_missing
        + runs_actual_not_positive + runs_scheduled_not_positive
        or net_excess_seconds
        != actual_run_seconds_sum - terminal_hold_in_actual_seconds_sum - scheduled_run_seconds_sum
        or positive_excess_seconds < net_excess_seconds
),

daily_totals as (
    select
        'all_days' as day_basis,
        sum(positive_excess_seconds) as positive_total,
        sum(net_excess_seconds) as net_total,
        sum(runs_compared) as runs,
        sum(long_run_positive_excess_seconds) as long_positive
    from {{ ref('mart_train_delay_daily') }}
    union all
    select
        'weekday' as day_basis,
        sum(positive_excess_seconds) as positive_total,
        sum(net_excess_seconds) as net_total,
        sum(runs_compared) as runs,
        sum(long_run_positive_excess_seconds) as long_positive
    from {{ ref('mart_train_delay_daily') }}
    where day_type = 'weekday'
),

summary_check as (
    select 'summary vs daily' as check_name
    from {{ ref('mart_train_delay_summary') }} as delay_summary
    inner join daily_totals on delay_summary.day_basis = daily_totals.day_basis
    where
        delay_summary.positive_excess_seconds != daily_totals.positive_total
        or delay_summary.net_excess_seconds != daily_totals.net_total
        or delay_summary.runs_compared != daily_totals.runs
        or delay_summary.long_run_positive_excess_seconds != daily_totals.long_positive
)

select * from tile_check
union all
select * from daily_check
union all
select * from summary_check
