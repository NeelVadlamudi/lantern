{{ config(materialized='table') }}
-- Duration label cases: seconds and the label format_duration gives them. The on-run-end hook
-- writes the seconds and label columns to out/duration_label_cases.json, and the board's own
-- formatter is tested against that file so both give the same label.
-- Cases: every unit boundary (seed duration_label_boundaries) plus large real values from the
-- marts, kept with their fractions so the flooring rule is exercised too.

with boundaries as (

    select
        sort_order,
        'boundary' as case_source,
        case_name,
        cast(seconds as double) as seconds
    from {{ ref('duration_label_boundaries') }}

),

rider_days as (

    select
        avg(rider_seconds_lost) filter (where day_type = 'weekday') as avg_weekday_rider_seconds_lost,
        avg(rider_seconds_lost) as avg_daily_rider_seconds_lost,
        sum(rider_seconds_lost) as window_rider_seconds_lost
    from {{ ref('mart_rider_time_lost_daily') }}
    where has_rider_data

),

largest_week as (

    select max(rider_seconds_lost) as rider_seconds_lost
    from {{ ref('mart_rider_time_lost_weekly') }}

),

top_segment as (

    select avg_weekday_positive_excess_seconds
    from {{ ref('mart_segment_reliability') }}
    where loss_rank = 1

),

train_delay as (

    select
        avg_daily_positive_excess_seconds,
        avg_daily_net_excess_seconds,
        positive_excess_seconds_per_run
    from {{ ref('mart_train_delay_summary') }}
    where day_basis = 'weekday'

),

real_values as (

    select
        101 as sort_order,
        'mart' as case_source,
        'average weekday rider time lost' as case_name,
        avg_weekday_rider_seconds_lost as seconds
    from rider_days
    union all
    select
        102 as sort_order,
        'mart' as case_source,
        'average daily rider time lost, all days' as case_name,
        avg_daily_rider_seconds_lost as seconds
    from rider_days
    union all
    select
        103 as sort_order,
        'mart' as case_source,
        'rider time lost over the whole window' as case_name,
        window_rider_seconds_lost as seconds
    from rider_days
    union all
    select
        104 as sort_order,
        'mart' as case_source,
        'largest weekly rider time lost' as case_name,
        rider_seconds_lost as seconds
    from largest_week
    union all
    select
        105 as sort_order,
        'mart' as case_source,
        'top segment, average weekday train delay' as case_name,
        avg_weekday_positive_excess_seconds as seconds
    from top_segment
    union all
    select
        106 as sort_order,
        'mart' as case_source,
        'average weekday train delay' as case_name,
        avg_daily_positive_excess_seconds as seconds
    from train_delay
    union all
    select
        107 as sort_order,
        'mart' as case_source,
        'average weekday train delay, net' as case_name,
        avg_daily_net_excess_seconds as seconds
    from train_delay
    union all
    select
        108 as sort_order,
        'mart' as case_source,
        'weekday train delay per run' as case_name,
        positive_excess_seconds_per_run as seconds
    from train_delay

),

cases as (

    select * from boundaries
    union all
    select * from real_values
    where seconds is not null

)

select
    cast(sort_order as integer) as sort_order,
    cast(case_source as varchar) as case_source,
    cast(case_name as varchar) as case_name,
    cast(seconds as double) as seconds,
    {{ format_duration('seconds') }} as label  -- noqa: RF04
from cases
order by sort_order
