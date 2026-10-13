-- Grain: one row per line scope ('system' or a GTFS route id), service date and segment.
-- Measured train delay on each segment that day (compared runs in fct_segment_traversals):
-- positive = sum of max(run - scheduled, 0), net = sum of (run - scheduled), with the run count.
-- day_rank orders segments within the scope and date by positive seconds (highest first, ties by
-- segment_id); the worst 3 feed the latest-day block. Typical = the var('typical_days') most
-- recent earlier service dates of the same day type on which the segment had compared runs in
-- that scope: median and mean of its positive seconds, and the exact difference.
-- A route scope counts only that route's runs (Green Line branches share trunk segments).

with traversals as (

    select
        route_id,
        segment_id,
        service_date,
        positive_excess_seconds,
        net_excess_seconds
    from {{ ref('fct_segment_traversals') }}
    where is_compared

),

scoped as (

    select
        route_id as scope_id,
        segment_id,
        service_date,
        count(*) as runs_compared,
        sum(positive_excess_seconds) as positive_excess_seconds,
        sum(net_excess_seconds) as net_excess_seconds
    from traversals
    group by route_id, segment_id, service_date

    union all

    select
        'system' as scope_id,
        segment_id,
        service_date,
        count(*) as runs_compared,
        sum(positive_excess_seconds) as positive_excess_seconds,
        sum(net_excess_seconds) as net_excess_seconds
    from traversals
    group by segment_id, service_date

),

typed_base as (

    select
        scoped.*,
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
        {{ planned_baseline_key('scope_id, segment_id, day_type') }} as baseline_key
    from typed_flagged

),

typical as (

    select
        typed.*,
        row_number() over (
            partition by typed.scope_id, typed.service_date
            order by typed.positive_excess_seconds desc, typed.segment_id asc
        ) as day_rank,
        median({{ typical_value('typed.positive_excess_seconds') }}) over typical_frame as typical_median,
        avg({{ typical_value('typed.positive_excess_seconds') }}) over typical_frame as typical_mean,
        count({{ typical_value('typed.positive_excess_seconds') }}) over typical_frame as typical_days
    from typed
    window typical_frame as ({{ typical_window_excluding('typed.scope_id, typed.segment_id, typed.day_type') }})

)

select
    {{ dbt_utils.generate_surrogate_key(['typical.scope_id', 'typical.service_date', 'typical.segment_id']) }}
        as segment_day_scope_key,
    cast(typical.scope_id as varchar) as scope_id,
    cast(typical.service_date as date) as service_date,
    cast(typical.date_key as integer) as date_key,
    cast(typical.day_type as varchar) as day_type,
    cast(typical.is_planned_change as boolean) as is_planned_change,
    cast(typical.segment_id as varchar) as segment_id,
    cast(segments.line_id as varchar) as line_id,
    cast(segments.direction_id as integer) as direction_id,
    cast(segments.from_station_id as varchar) as from_station_id,
    cast(segments.to_station_id as varchar) as to_station_id,
    cast(typical.runs_compared as bigint) as runs_compared,
    cast(typical.positive_excess_seconds as double) as positive_excess_seconds,
    cast(typical.net_excess_seconds as double) as net_excess_seconds,
    cast(typical.positive_excess_seconds / typical.runs_compared as double) as positive_excess_per_run_seconds,
    cast(typical.net_excess_seconds / typical.runs_compared as double) as net_excess_per_run_seconds,
    cast(typical.day_rank as bigint) as day_rank,
    cast(typical.typical_days as bigint) as typical_days,
    cast(typical.typical_median as double) as typical_median_positive_seconds,
    cast(typical.typical_mean as double) as typical_mean_positive_seconds,
    cast(typical.positive_excess_seconds - typical.typical_median as double) as diff_vs_median_seconds,
    cast(typical.positive_excess_seconds - typical.typical_mean as double) as diff_vs_mean_seconds
from typical
inner join {{ ref('dim_segments') }} as segments on typical.segment_id = segments.segment_id
