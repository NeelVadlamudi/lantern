-- Shares on the board are in range and add up: segment delay shares (positive excess, so 0 to 1)
-- and line late and long-gap shares lie between 0 and 1; segment delay shares and station-line
-- loss shares (signed: net rider time lost can be negative, never clamped) each sum to 1 per
-- window. Returns one row per broken rule.

with segment_totals as (
    select
        sum(delay_share_recent) as recent_total,
        sum(delay_share_prior) as prior_total
    from {{ ref('mart_segment_trend') }}
),

station_totals as (
    select
        sum(loss_share_recent) as recent_total,
        sum(loss_share_prior) as prior_total
    from {{ ref('mart_station_trend') }}
),

checks as (
    select
        'segment delay share out of range' as rule_name,
        count(*) as bad_rows
    from {{ ref('mart_segment_trend') }}
    where delay_share_recent not between 0 and 1 or delay_share_prior not between 0 and 1
    union all
    select
        'segment delay shares do not sum to 1' as rule_name,
        count(*) as bad_rows
    from segment_totals
    where abs(recent_total - 1) > 1e-9 or abs(prior_total - 1) > 1e-9
    union all
    select
        'station loss shares do not sum to 1' as rule_name,
        count(*) as bad_rows
    from station_totals
    where abs(recent_total - 1) > 1e-9 or abs(prior_total - 1) > 1e-9
    union all
    select
        'line late or long-gap share out of range' as rule_name,
        count(*) as bad_rows
    from {{ ref('mart_line_daily_reliability') }}
    where late_trip_share not between 0 and 1 or long_gap_share not between 0 and 1
)

select
    rule_name,
    bad_rows
from checks
where bad_rows > 0
