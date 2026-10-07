-- Grain: one row per station, line, day type and service period.
-- Average daily fare-gate entries, used to weight reliability by riders.
-- Basis: the last var('rider_basis_days') days of gated-entry data that end on or before the
-- latest loaded LAMP service date. Gated entries are published with a lag (the feed ends weeks
-- before LAMP does), so the basis dates are stored on every row instead of assumed.
-- Only gated stations appear: Green Line surface stops and most Mattapan stops have no fare gates.

with entries as (

    select * from {{ ref('stg_mbta__gated_entries') }}

),

line_map as (

    select * from {{ ref('gated_entry_lines') }}

),

periods as (

    select * from {{ ref('int_service_periods') }}

),

basis as (

    select
        max(entries.service_date) as basis_end_date,
        max(entries.service_date) - {{ var('rider_basis_days') }} + 1 as basis_start_date
    from entries
    where entries.service_date <= (
            select max(lamp.service_date) from {{ ref('stg_lamp__subway_trip_stops') }} as lamp
        )

),

in_basis as (

    select
        entries.service_date,
        entries.station_id,
        line_map.line_id,
        periods.service_period_id,
        {{ day_type('entries.service_date') }} as day_type,
        entries.gated_entries
    from entries
    cross join basis
    inner join line_map
        on entries.route_or_line = line_map.route_or_line
    inner join periods
        on entries.bin_start_minute = periods.minute_of_day
    where
        entries.service_date between basis.basis_start_date and basis.basis_end_date
        and line_map.line_id is not null
        and entries.station_id is not null

),

days_per_type as (

    select
        day_type,
        count(distinct service_date) as basis_days
    from in_basis
    group by day_type

)

select
    in_basis.station_id,
    in_basis.line_id,
    in_basis.day_type,
    in_basis.service_period_id,
    -- Entries carry at most two decimals; summing them as DECIMAL keeps the sum exact, so the
    -- average is the same on every build (a DOUBLE sum depends on the order rows arrive in).
    sum(cast(in_basis.gated_entries as decimal(18, 2))) / max(days_per_type.basis_days)
        as avg_daily_gated_entries,
    max(days_per_type.basis_days) as basis_days,
    max(basis.basis_start_date) as basis_start_date,
    max(basis.basis_end_date) as basis_end_date
from in_basis
inner join days_per_type
    on in_basis.day_type = days_per_type.day_type
cross join basis
group by in_basis.station_id, in_basis.line_id, in_basis.day_type, in_basis.service_period_id
