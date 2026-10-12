-- Gate entries reconcile: for every date with a rider weight, the entries at cells with recorded
-- trains plus the entries at cells without (gated_entries_no_trains) equal all the rider weights
-- for the date's day type (int_station_period_riders), and the no-train cells are counted.
with weights as (
    select
        day_type,
        sum(cast(avg_daily_gated_entries as double)) as all_entries,
        count(*) as all_cells
    from {{ ref('int_station_period_riders') }}
    group by day_type
),

cells as (
    select
        date_key,
        count(*) filter (where has_rider_data) as cells_with_riders
    from {{ ref('mart_station_rider_time_lost') }}
    group by date_key
)

select
    daily.service_date,
    daily.gated_entries,
    daily.gated_entries_no_trains,
    weights.all_entries
from {{ ref('mart_rider_time_lost_daily') }} as daily
inner join weights on daily.day_type = weights.day_type
inner join cells on daily.date_key = cells.date_key
where
    daily.has_rider_data
    and (
        abs(daily.gated_entries_all_cells - weights.all_entries) > 1e-6 * weights.all_entries
        or abs(daily.gated_entries + daily.gated_entries_no_trains - daily.gated_entries_all_cells) > 1e-6
        or cells.cells_with_riders + daily.cells_no_trains != weights.all_cells
    )
