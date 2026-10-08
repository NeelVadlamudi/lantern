-- board_data.json decision block matches the marts: top-10 segments and their share of the
-- segment train delay, the cause counts, the terminal segment count, the gaps over 1 hour and
-- the getting-worse lists (tolerance 1e-9).
with payload as (
    select decision from {{ ref('board_payload') }}
),

segments as (
    select * from {{ ref('mart_segment_reliability') }}
),

expected as (
    select
        sum(avg_weekday_positive_excess_seconds) filter (where is_top_10)
        / sum(avg_weekday_positive_excess_seconds) as top_10_share,
        count(*) filter (where is_terminal_departure or is_terminal_arrival) as terminal_segments,
        (select count(*) from {{ ref('fct_suspension_gaps') }}) as gap_count,
        (select sum(gaps.gap_seconds) from {{ ref('fct_suspension_gaps') }} as gaps) as gap_seconds,
        count(*) filter (where is_top_10) as top_10_count,
        count(*) filter (where cause_class = 'schedule') as schedule_count,
        count(*) filter (where cause_class = 'service') as service_count,
        count(*) filter (where cause_class = 'mixed') as mixed_count,
        (
            select count(*) from {{ ref('mart_segment_trend') }} as segment_trend
            where segment_trend.is_getting_worse
        ) as worse_segments,
        (
            select count(*) from {{ ref('mart_station_trend') }} as station_trend
            where station_trend.is_getting_worse
        ) as worse_stations
    from segments
)

select
    expected.*,
    payload.decision
from expected
cross join payload
where
    abs(
        cast(payload.decision -> 'segments' ->> 'top_10_share_of_segment_train_delay' as double)
        - expected.top_10_share
    )
    > 1e-9
    or cast(payload.decision -> 'segments' ->> 'terminal_segments' as bigint) != expected.terminal_segments
    or cast(payload.decision -> 'rider_time_lost' -> 'suspension_gaps' ->> 'count' as bigint) != expected.gap_count
    or cast(payload.decision -> 'rider_time_lost' -> 'suspension_gaps' ->> 'seconds' as bigint)
    != coalesce(expected.gap_seconds, 0)
    or json_array_length(payload.decision -> 'segments' -> 'top_10') != expected.top_10_count
    or coalesce(cast(payload.decision -> 'cause_counts' ->> 'schedule' as bigint), 0) != expected.schedule_count
    or coalesce(cast(payload.decision -> 'cause_counts' ->> 'service' as bigint), 0) != expected.service_count
    or coalesce(cast(payload.decision -> 'cause_counts' ->> 'mixed' as bigint), 0) != expected.mixed_count
    or json_array_length(payload.decision -> 'getting_worse' -> 'segments') != expected.worse_segments
    or json_array_length(payload.decision -> 'getting_worse' -> 'stations') != expected.worse_stations
