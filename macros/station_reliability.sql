{#- Station x line x day type x service period reliability with rider exposure (shared body of
    mart_station_reliability and mart_station_reliability_planned). With split_planned, every
    station-day takes is_planned_change from its line's scope-day (mart_planned_change_scope_days,
    scope_type 'line'; Green = any branch) and rows are split on it. -#}
{% macro station_reliability(split_planned=false) %}
{%- set key_columns = ['stats.station_id', 'stats.line_id', 'stats.day_type', 'stats.service_period_id'] -%}
{%- if split_planned %}{% do key_columns.append('stats.is_planned_change') %}{% endif -%}
with events as (

    select
        e.*,
        d.day_type{% if split_planned %},
        planned.is_planned_change{% endif %}
    from {{ ref('fct_trip_stop_events') }} as e
    inner join {{ ref('dim_dates') }} as d
        on e.date_key = d.date_key
    {%- if split_planned %}
    inner join {{ ref('mart_planned_change_scope_days') }} as planned
        on planned.scope_type = 'line' and e.line_id = planned.scope_id and e.service_date = planned.service_date
    {%- endif %}
    where e.station_id is not null
        and e.service_period_id is not null

),

stats as (

    select
        station_id,
        line_id,
        day_type,
        service_period_id,{% if split_planned %}
        is_planned_change,{% endif %}
        count(distinct service_date) as service_days,
        count(*) as trip_stop_events,
        count(*) filter (where has_travel_comparison) as travel_comparisons,
        avg(excess_travel_seconds) as avg_excess_travel_seconds,
        count(*) filter (where has_headway_comparison) as headway_observations,
        avg(cast(is_long_gap as int)) filter (where has_headway_comparison) as long_gap_share,
        avg(cast(is_headway_adherent as int)) filter (where has_headway_comparison) as headway_adherence_share,
        median(headway_seconds) filter (where has_headway_comparison) as median_headway_seconds,
        median(scheduled_headway_seconds) filter (where has_headway_comparison) as median_scheduled_headway_seconds
    from events
    group by station_id, line_id, day_type, service_period_id{% if split_planned %}, is_planned_change{% endif %}

),

riders as (

    select * from {{ ref('int_station_period_riders') }}

)

select
    {{ dbt_utils.generate_surrogate_key(key_columns) }} as station_period_key,
    cast(stats.station_id as varchar) as station_id,
    cast(stats.line_id as varchar) as line_id,
    cast(stats.day_type as varchar) as day_type,
    cast(stats.service_period_id as varchar) as service_period_id,{% if split_planned %}
    cast(stats.is_planned_change as boolean) as is_planned_change,{% endif %}
    cast(stats.service_days as bigint) as service_days,
    cast(stats.trip_stop_events as bigint) as trip_stop_events,
    cast(stats.travel_comparisons as bigint) as travel_comparisons,
    cast(stats.avg_excess_travel_seconds as double) as avg_excess_travel_seconds,
    cast(stats.headway_observations as bigint) as headway_observations,
    cast(stats.long_gap_share as double) as long_gap_share,
    cast(stats.headway_adherence_share as double) as headway_adherence_share,
    cast(stats.median_headway_seconds as double) as median_headway_seconds,
    cast(stats.median_scheduled_headway_seconds as double) as median_scheduled_headway_seconds,
    riders.station_id is not null as has_rider_data,
    cast(riders.avg_daily_gated_entries as double) as avg_daily_gated_entries,
    -- estimated entries during this cell over the whole window: daily average x service days
    cast(riders.avg_daily_gated_entries * stats.service_days as double) as est_window_gated_entries,
    -- exposure index: estimated entries made while trains here were running a long gap
    cast(riders.avg_daily_gated_entries * stats.service_days * stats.long_gap_share as double)
        as est_window_entries_in_long_gaps,
    cast(riders.basis_start_date as date) as rider_basis_start_date,
    cast(riders.basis_end_date as date) as rider_basis_end_date
from stats
left join riders
    on stats.station_id = riders.station_id
        and stats.line_id = riders.line_id
        and stats.day_type = riders.day_type
        and stats.service_period_id = riders.service_period_id
{% endmacro %}
