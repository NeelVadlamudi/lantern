-- board_data.json decision block matches the marts: top-10 segments and their share of the
-- positive segment loss, the cause counts, and the getting-worse lists (tolerance 1e-9).
with payload as (
    select decision from {{ ref('board_payload') }}
),

segments as (
    select * from {{ ref('mart_segment_reliability') }}
),

expected as (
    select
        sum(avg_weekday_rider_seconds_lost) filter (where is_top_10)
        / sum(greatest(avg_weekday_rider_seconds_lost, 0)) as top_10_share,
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
    abs(cast(payload.decision -> 'segments' ->> 'top_10_share_of_segment_loss' as double) - expected.top_10_share)
    > 1e-9
    or json_array_length(payload.decision -> 'segments' -> 'top_10') != expected.top_10_count
    or coalesce(cast(payload.decision -> 'cause_counts' ->> 'schedule' as bigint), 0) != expected.schedule_count
    or coalesce(cast(payload.decision -> 'cause_counts' ->> 'service' as bigint), 0) != expected.service_count
    or coalesce(cast(payload.decision -> 'cause_counts' ->> 'mixed' as bigint), 0) != expected.mixed_count
    or json_array_length(payload.decision -> 'getting_worse' -> 'segments') != expected.worse_segments
    or json_array_length(payload.decision -> 'getting_worse' -> 'stations') != expected.worse_stations
