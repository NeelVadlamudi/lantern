-- Chart exports add up: histogram bins sum to the compared trips and runs, and each period's line
-- shares of train delay sum to 1.
with hist as (
    select
        kind,
        sum(observations) as observations
    from {{ ref('mart_delay_histogram') }}
    where scope_id = 'system'
    group by kind
),

expected as (
    select
        'trip' as kind,
        count(*) as n
    from {{ ref('fct_trips') }}
    where compared_segments > 0 and is_matched_trip
        and service_date >= (select min(date_day) from {{ ref('dim_dates') }})
    union all
    select
        'run' as kind,
        count(*) as n
    from {{ ref('int_train_runs') }}
    where run_comparison_status = 'compared'
        and service_date >= (select min(date_day) from {{ ref('dim_dates') }})
),

shares as (
    select
        period_kind,
        service_date,
        sum(share_of_positive_excess) as total_share
    from {{ ref('mart_train_delay_by_line') }}
    group by period_kind, service_date
)

select 'histogram ' || expected.kind as failure
from expected
left join hist on expected.kind = hist.kind
where hist.observations is distinct from expected.n

union all

select 'shares ' || period_kind as failure
from shares
where abs(total_share - 1) > 1e-9
