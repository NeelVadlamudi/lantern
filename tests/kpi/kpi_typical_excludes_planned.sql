-- Typical values never use a day with a planned service change. For every route and the
-- system scope in mart_line_day_metrics, the late-share typical median is recomputed from the
-- daily rows: the median of the latest var('typical_days') earlier dates of the same day type
-- without a planned change and with a value. Planned days stay in the day view, labelled.
-- Tolerance 1e-12.
with days as (
    select
        scope_id,
        service_date,
        day_type,
        is_planned_change,
        planned_change_label,
        value,
        typical_days,
        typical_median,
        typical_first_date,
        typical_last_date
    from {{ ref('mart_line_day_metrics') }}
    where measure = 'late_trip_share'
),

recomputed as (
    select
        days.scope_id,
        days.service_date,
        days.typical_days,
        days.typical_median,
        (
            select median(earlier.value)
            from (
                select prior_day.value
                from days as prior_day
                where
                    prior_day.scope_id = days.scope_id
                    and prior_day.day_type = days.day_type
                    and prior_day.service_date < days.service_date
                    and not prior_day.is_planned_change
                    and prior_day.value is not null
                order by prior_day.service_date desc
                limit {{ var('typical_days') }}
            ) as earlier
        ) as expected_median
    from days
)

select
    'typical median' as check_name,
    scope_id,
    service_date
from recomputed
where
    (typical_median is null) != (expected_median is null)
    or abs(typical_median - expected_median) > 1e-12

union all

select
    'typical window ends on a planned day' as check_name,
    days.scope_id,
    days.service_date
from days
inner join days as last_day
    on
        days.scope_id = last_day.scope_id
        and days.typical_last_date = last_day.service_date
where last_day.is_planned_change

union all

select
    'planned day without label' as check_name,
    scope_id,
    service_date
from days
where is_planned_change and planned_change_label is null
