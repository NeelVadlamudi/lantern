-- DST handling, checked on fixed timestamps (no data needed), so it runs in every build:
--   * to_boston_time() turns the two 1:30 AMs of 2026-11-01 (05:30 and 06:30 UTC) into the same
--     wall-clock 01:30, and service_hour() puts both in service hour 25 of 2026-10-31
--   * dst_extra_hours() is +1 for 2026-10-31 (fall back the next morning), -1 for 2026-03-07
--     (spring forward), 0 for an ordinary date
-- Any row returned is a failure.
with cases as (
    select
        cases_values.utc_at,
        cases_values.service_date,
        cases_values.expected_hour
    from (
        values
        (timestamptz '2026-11-01 05:30:00+00', date '2026-10-31', 25),
        (timestamptz '2026-11-01 06:30:00+00', date '2026-10-31', 25),
        (timestamptz '2026-11-01 07:30:00+00', date '2026-10-31', 26),
        (timestamptz '2026-11-01 10:15:00+00', date '2026-11-01', 5),
        (timestamptz '2026-03-08 07:30:00+00', date '2026-03-07', 27),
        (timestamptz '2026-08-27 12:00:00+00', date '2026-08-27', 8)
    ) as cases_values (utc_at, service_date, expected_hour)
),

hours as (
    select
        utc_at,
        service_date,
        expected_hour,
        {{ service_hour(to_boston_time('utc_at'), 'service_date') }} as service_hour
    from cases
),

dst as (
    select
        dst_values.service_date,
        dst_values.expected_extra
    from (
        values
        (date '2026-10-31', 1),
        (date '2026-03-07', -1),
        (date '2026-08-27', 0),
        (date '2026-11-01', 0)
    ) as dst_values (service_date, expected_extra)
)

select
    'service_hour' as check_name,
    cast(utc_at as varchar) as input_value,
    service_hour as got
from hours
where service_hour != expected_hour

union all

select
    'dst_extra_hours' as check_name,
    cast(service_date as varchar) as input_value,
    {{ dst_extra_hours('service_date') }} as got
from dst
where {{ dst_extra_hours('service_date') }} != expected_extra
