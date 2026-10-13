-- Grain: one row per line scope ('system' or a GTFS route id), service date and station.
-- Long gaps that day: departures more than var('long_gap_ratio') (1.5) times the scheduled gap
-- after the previous train on the line, out of the departures with a headway comparison
-- (fct_trip_stop_events). day_rank orders stations within the scope and date by long gaps
-- (most first, then by share, then station_id); the worst 3 feed the latest-day block.
-- Typical = the var('typical_days') most recent earlier service dates of the same day type on
-- which the station had departures in that scope: median and mean of long gaps and of the share.

with departures as (

    select
        route_id,
        station_id,
        service_date,
        is_long_gap
    from {{ ref('fct_trip_stop_events') }}
    where has_headway_comparison

),

scoped as (

    select
        route_id as scope_id,
        station_id,
        service_date,
        count(*) as headway_observations,
        count(*) filter (where is_long_gap) as long_gaps
    from departures
    group by route_id, station_id, service_date

    union all

    select
        'system' as scope_id,
        station_id,
        service_date,
        count(*) as headway_observations,
        count(*) filter (where is_long_gap) as long_gaps
    from departures
    group by station_id, service_date

),

typed_base as (

    select
        scoped.*,
        scoped.long_gaps / scoped.headway_observations as long_gap_share,
        dates.date_key,
        dates.day_type
    from scoped
    inner join {{ ref('dim_dates') }} as dates on scoped.service_date = dates.date_day

),

typed_flagged as (

    select
        typed_base.*,
        coalesce(planned.is_planned_change, false) as is_planned_change
    from typed_base
    left join {{ ref('mart_planned_change_scope_days') }} as planned
        on
            planned.scope_type = 'route'
            and typed_base.scope_id = planned.scope_id
            and typed_base.service_date = planned.service_date

),

typed as (

    select
        typed_flagged.*,
        {{ planned_baseline_key('scope_id, station_id, day_type') }} as baseline_key
    from typed_flagged

),

typical as (

    select
        typed.*,
        row_number() over (
            partition by typed.scope_id, typed.service_date
            order by typed.long_gaps desc, typed.long_gap_share desc, typed.station_id asc
        ) as day_rank,
        median({{ typical_value('typed.long_gaps') }}) over typical_frame as typical_median_long_gaps,
        avg({{ typical_value('typed.long_gaps') }}) over typical_frame as typical_mean_long_gaps,
        median({{ typical_value('typed.long_gap_share') }}) over typical_frame as typical_median_long_gap_share,
        avg({{ typical_value('typed.long_gap_share') }}) over typical_frame as typical_mean_long_gap_share,
        count({{ typical_value('1') }}) over typical_frame as typical_days
    from typed
    window typical_frame as ({{ typical_window_excluding('typed.scope_id, typed.station_id, typed.day_type') }})

)

select
    {{ dbt_utils.generate_surrogate_key(['scope_id', 'service_date', 'station_id']) }} as station_day_scope_key,
    cast(scope_id as varchar) as scope_id,
    cast(service_date as date) as service_date,
    cast(date_key as integer) as date_key,
    cast(day_type as varchar) as day_type,
    cast(is_planned_change as boolean) as is_planned_change,
    cast(station_id as varchar) as station_id,
    cast(headway_observations as bigint) as headway_observations,
    cast(long_gaps as bigint) as long_gaps,
    cast(long_gap_share as double) as long_gap_share,
    cast(day_rank as bigint) as day_rank,
    cast(typical_days as bigint) as typical_days,
    cast(typical_median_long_gaps as double) as typical_median_long_gaps,
    cast(typical_mean_long_gaps as double) as typical_mean_long_gaps,
    cast(long_gaps - typical_median_long_gaps as double) as diff_vs_median_long_gaps,
    cast(long_gaps - typical_mean_long_gaps as double) as diff_vs_mean_long_gaps,
    cast(typical_median_long_gap_share as double) as typical_median_long_gap_share,
    cast(typical_mean_long_gap_share as double) as typical_mean_long_gap_share,
    cast(long_gap_share - typical_median_long_gap_share as double) as diff_vs_median_long_gap_share,
    cast(long_gap_share - typical_mean_long_gap_share as double) as diff_vs_mean_long_gap_share
from typical
