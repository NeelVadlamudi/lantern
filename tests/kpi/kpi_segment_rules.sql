-- Segment rules recomputed from the stored columns:
--   cause_class follows the documented rule (cause_min_days, cause_dominance_ratio);
--   is_getting_worse is set exactly when the volume and delta thresholds are met;
--   loss_rank runs 1..n over segments with rider data, and is_top_10 is rank <= 10;
--   buffer_seconds >= 0.
with reliability as (
    select
        *,
        case
            when cause_days < {{ var('cause_min_days') }} then 'insufficient_data'
            when abs(bias_seconds) >= {{ var('cause_dominance_ratio') }} * variability_iqr_seconds then 'schedule'
            when variability_iqr_seconds >= {{ var('cause_dominance_ratio') }} * abs(bias_seconds) then 'service'
            else 'mixed'
        end as expected_class,
        row_number() over (
            partition by has_rider_data order by avg_weekday_rider_seconds_lost desc, segment_id asc
        ) as expected_rank
    from {{ ref('mart_segment_reliability') }}
),

trend as (
    select
        *,
        coalesce(
            runs_recent >= {{ var('worse_min_volume_recent') }}
            and runs_prior >= {{ var('worse_min_volume_prior') }}
            and delta_excess_seconds >= {{ var('worse_min_delta_seconds') }}
            and delta_excess_seconds >= typical_delta_excess_seconds + {{ var('worse_min_delta_seconds') }},
            false
        ) as expected_worse
    from {{ ref('mart_segment_trend') }}
),

station_trend as (
    select
        *,
        coalesce(
            departures_recent >= {{ var('worse_min_volume_recent') }}
            and departures_prior >= {{ var('worse_min_volume_prior') }}
            and delta_excess_seconds >= {{ var('worse_min_delta_seconds') }}
            and delta_excess_seconds >= typical_delta_excess_seconds + {{ var('worse_min_delta_seconds') }},
            false
        ) as expected_worse
    from {{ ref('mart_station_trend') }}
)

select
    'cause_class' as rule_name,
    segment_id as row_id
from reliability
where cause_class != expected_class
union all
select
    'loss_rank' as rule_name,
    segment_id as row_id
from reliability
where
    (has_rider_data and (loss_rank != expected_rank or is_top_10 != (expected_rank <= 10)))
    or (not has_rider_data and (loss_rank is not null or is_top_10))
union all
select
    'buffer' as rule_name,
    segment_id as row_id
from reliability
where buffer_seconds < 0
union all
select
    'segment getting worse' as rule_name,
    segment_id as row_id
from trend
where is_getting_worse != expected_worse
union all
select
    'station getting worse' as rule_name,
    station_line_key as row_id
from station_trend
where is_getting_worse != expected_worse
