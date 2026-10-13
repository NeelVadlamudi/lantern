-- Grain: one row per line scope ('system', a GTFS route id, or 'Green' = the four Green Line
-- branches combined), service date and measure.
-- One day's plain figures with a typical value to compare against. Typical = the
-- var('typical_days') (28) most recent earlier service dates of the same day type on which the
-- scope had the measure (fewer near the start of the window; typical_days gives the count):
-- median and mean of the daily values, and the exact difference from each.
-- Measures:
--   late_trips, trips_compared, late_trip_share     fct_trips via mart_line_daily_reliability
--                                                    (runs over 30 minutes included)
--   runs_compared, train_delay_positive_seconds,     int_train_runs (compared runs): positive =
--   train_delay_net_seconds, *_per_run_seconds       sum of max(run - scheduled, 0), net = sum of
--                                                    (run - scheduled), per run = / runs_compared
--   long_gaps, headway_observations, long_gap_share  mart_line_daily_reliability
--   bunched_departures, gapped_departures,           mart_headway_adherence (SFMTA rules: under
--   departures_compared, bunched_share, gapped_share 2 min / over scheduled + 5 min)
--   scheduled_trips, completeness_share              mart_line_day_completeness (trips compared /
--                                                    trips in the GTFS schedule for the date)
--   unmatched_trips_compared, added_trips_compared   compared runs whose trip id is not in the
--                                                    day's schedule (not in the late share)
-- Shares and per-run values are the day's own ratio (numerator / denominator, both given); the
-- typical value is the median or mean of the earlier days' ratios.
-- Planned service changes (mart_planned_change_line_days): is_planned_change is the line-day's
-- flag for a route, any branch for 'Green', any line for 'system' (planned_change_lines counts
-- them). Every day keeps its row and label, but the typical value is taken only from earlier
-- days without a planned change: the var('typical_days') most recent earlier days of the same
-- day type with is_planned_change false.

with adherence_days as (

    select
        scope_id,
        service_date,
        sum(departures_compared) as departures_compared,
        sum(bunched_departures) as bunched_departures,
        sum(gapped_departures) as gapped_departures
    from {{ ref('mart_headway_adherence') }}
    group by scope_id, service_date

    union all

    select
        'Green' as scope_id,
        service_date,
        sum(departures_compared) as departures_compared,
        sum(bunched_departures) as bunched_departures,
        sum(gapped_departures) as gapped_departures
    from {{ ref('mart_headway_adherence') }}
    where scope_id like 'Green-%'
    group by service_date

),

completeness_days as (

    select
        scope_id,
        service_date,
        scheduled_trips,
        trips_compared as completeness_trips_compared
    from {{ ref('mart_line_day_completeness') }}
    where scheduled_trips > 0

    union all

    select
        'Green' as scope_id,
        service_date,
        sum(scheduled_trips) as scheduled_trips,
        sum(trips_compared) as completeness_trips_compared
    from {{ ref('mart_line_day_completeness') }}
    where scope_id like 'Green-%'
    group by service_date
    having sum(scheduled_trips) > 0

),

line_days as (

    select
        route_id as scope_id,
        service_date,
        late_trips,
        trips_compared,
        unmatched_trips_compared,
        added_trips_compared,
        long_gaps,
        headway_observations
    from {{ ref('mart_line_daily_reliability') }}

    union all

    select
        'system' as scope_id,
        service_date,
        sum(late_trips) as late_trips,
        sum(trips_compared) as trips_compared,
        sum(unmatched_trips_compared) as unmatched_trips_compared,
        sum(added_trips_compared) as added_trips_compared,
        sum(long_gaps) as long_gaps,
        sum(headway_observations) as headway_observations
    from {{ ref('mart_line_daily_reliability') }}
    group by service_date

    union all

    select
        'Green' as scope_id,
        service_date,
        sum(late_trips) as late_trips,
        sum(trips_compared) as trips_compared,
        sum(unmatched_trips_compared) as unmatched_trips_compared,
        sum(added_trips_compared) as added_trips_compared,
        sum(long_gaps) as long_gaps,
        sum(headway_observations) as headway_observations
    from {{ ref('mart_line_daily_reliability') }}
    where route_id like 'Green-%'
    group by service_date

),

planned_days as (

    select
        route_id as scope_id,
        service_date,
        is_planned_change,
        cast(is_planned_change as integer) as planned_change_lines,
        planned_change_label
    from {{ ref('mart_planned_change_line_days') }}

    union all

    select
        'system' as scope_id,
        service_date,
        bool_or(is_planned_change) as is_planned_change,
        count(*) filter (where is_planned_change) as planned_change_lines,
        case
            when bool_or(is_planned_change)
                then 'Planned service change on '
                    || string_agg(route_id, ', ' order by route_id) filter (where is_planned_change)
        end as planned_change_label
    from {{ ref('mart_planned_change_line_days') }}
    group by service_date

    union all

    select
        'Green' as scope_id,
        service_date,
        bool_or(is_planned_change) as is_planned_change,
        count(*) filter (where is_planned_change) as planned_change_lines,
        case
            when bool_or(is_planned_change)
                then 'Planned service change on '
                    || string_agg(route_id, ', ' order by route_id) filter (where is_planned_change)
        end as planned_change_label
    from {{ ref('mart_planned_change_line_days') }}
    where route_id like 'Green-%'
    group by service_date

),

runs as (

    select
        route_id,
        service_date,
        positive_excess_seconds,
        net_excess_seconds
    from {{ ref('int_train_runs') }}
    where is_compared

),

delay_days as (

    select
        route_id as scope_id,
        service_date,
        count(*) as runs_compared,
        sum(positive_excess_seconds) as positive_seconds,
        sum(net_excess_seconds) as net_seconds
    from runs
    group by route_id, service_date

    union all

    select
        'system' as scope_id,
        service_date,
        count(*) as runs_compared,
        sum(positive_excess_seconds) as positive_seconds,
        sum(net_excess_seconds) as net_seconds
    from runs
    group by service_date

    union all

    select
        'Green' as scope_id,
        service_date,
        count(*) as runs_compared,
        sum(positive_excess_seconds) as positive_seconds,
        sum(net_excess_seconds) as net_seconds
    from runs
    where route_id like 'Green-%'
    group by service_date

),

joined_days as (

    select
        coalesce(line_days.scope_id, delay_days.scope_id) as scope_id,
        coalesce(line_days.service_date, delay_days.service_date) as service_date,
        line_days.late_trips,
        line_days.trips_compared,
        line_days.unmatched_trips_compared,
        line_days.added_trips_compared,
        line_days.long_gaps,
        line_days.headway_observations,
        delay_days.runs_compared,
        delay_days.positive_seconds,
        delay_days.net_seconds
    from line_days
    full outer join delay_days
        on
            line_days.scope_id = delay_days.scope_id
            and line_days.service_date = delay_days.service_date

),

days as (

    select
        joined_days.*,
        adherence_days.departures_compared,
        adherence_days.bunched_departures,
        adherence_days.gapped_departures,
        completeness_days.scheduled_trips,
        completeness_days.completeness_trips_compared
    from joined_days
    left join adherence_days
        on
            joined_days.scope_id = adherence_days.scope_id
            and joined_days.service_date = adherence_days.service_date
    left join completeness_days
        on
            joined_days.scope_id = completeness_days.scope_id
            and joined_days.service_date = completeness_days.service_date

),

measures as (

    {% set measures = [
        ('late_trips', 'count', 'late_trips', 'null', 'null'),
        ('trips_compared', 'count', 'trips_compared', 'null', 'null'),
        ('unmatched_trips_compared', 'count', 'unmatched_trips_compared', 'null', 'null'),
        ('added_trips_compared', 'count', 'added_trips_compared', 'null', 'null'),
        ('late_trip_share', 'share', 'late_trips / nullif(trips_compared, 0)', 'late_trips', 'trips_compared'),
        ('runs_compared', 'count', 'runs_compared', 'null', 'null'),
        ('train_delay_positive_seconds', 'seconds', 'positive_seconds', 'null', 'null'),
        ('train_delay_net_seconds', 'seconds', 'net_seconds', 'null', 'null'),
        ('train_delay_positive_per_run_seconds', 'seconds', 'positive_seconds / nullif(runs_compared, 0)',
            'positive_seconds', 'runs_compared'),
        ('train_delay_net_per_run_seconds', 'seconds', 'net_seconds / nullif(runs_compared, 0)',
            'net_seconds', 'runs_compared'),
        ('long_gaps', 'count', 'long_gaps', 'null', 'null'),
        ('headway_observations', 'count', 'headway_observations', 'null', 'null'),
        ('long_gap_share', 'share', 'long_gaps / nullif(headway_observations, 0)', 'long_gaps',
            'headway_observations'),
        ('departures_compared', 'count', 'departures_compared', 'null', 'null'),
        ('bunched_departures', 'count', 'bunched_departures', 'null', 'null'),
        ('gapped_departures', 'count', 'gapped_departures', 'null', 'null'),
        ('bunched_share', 'share', 'bunched_departures / nullif(departures_compared, 0)', 'bunched_departures',
            'departures_compared'),
        ('gapped_share', 'share', 'gapped_departures / nullif(departures_compared, 0)', 'gapped_departures',
            'departures_compared'),
        ('scheduled_trips', 'count', 'scheduled_trips', 'null', 'null'),
        ('completeness_share', 'ratio', 'completeness_trips_compared / nullif(scheduled_trips, 0)',
            'completeness_trips_compared', 'scheduled_trips'),
    ] %}
    {% for name, unit, expr, num, den in measures %}
        select
            scope_id,
            service_date,
            '{{ name }}' as measure,
            '{{ unit }}' as unit,
            cast({{ expr }} as double) as value,
            cast({{ num }} as double) as numerator,
            cast({{ den }} as double) as denominator
        from days
        where {{ expr }} is not null
        {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

typed as (

    select
        measures.*,
        dates.date_key,
        dates.day_type,
        coalesce(planned_days.is_planned_change, false) as is_planned_change,
        coalesce(planned_days.planned_change_lines, 0) as planned_change_lines,
        planned_days.planned_change_label
    from measures
    inner join {{ ref('dim_dates') }} as dates on measures.service_date = dates.date_day
    left join planned_days
        on measures.scope_id = planned_days.scope_id and measures.service_date = planned_days.service_date

),

-- typical statistics as of each day without a planned change, over it and the earlier such days
-- (var('typical_days') rows); each day then takes the last such row strictly before it
baseline as (

    select
        scope_id,
        measure,
        day_type,
        service_date,
        median(value) over baseline_frame as typical_median,
        avg(value) over baseline_frame as typical_mean,
        quantile_cont(value, 0.25) over baseline_frame as typical_p25,
        quantile_cont(value, 0.75) over baseline_frame as typical_p75,
        count(value) over baseline_frame as typical_days,
        min(service_date) over baseline_frame as typical_first_date,
        max(service_date) over baseline_frame as typical_last_date
    from typed
    where not is_planned_change
    window baseline_frame as (
        partition by scope_id, measure, day_type
        order by service_date
        rows between {{ var('typical_days') - 1 }} preceding and current row
    )

),

typical as (

    select
        typed.*,
        baseline.typical_median,
        baseline.typical_mean,
        baseline.typical_p25,
        baseline.typical_p75,
        baseline.typical_days,
        baseline.typical_first_date,
        baseline.typical_last_date
    from typed
    asof left join baseline
        on
            typed.scope_id = baseline.scope_id
            and typed.measure = baseline.measure
            and typed.day_type = baseline.day_type
            and typed.service_date > baseline.service_date

)

select
    {{ dbt_utils.generate_surrogate_key(['scope_id', 'service_date', 'measure']) }} as line_day_measure_key,
    cast(scope_id as varchar) as scope_id,
    cast(service_date as date) as service_date,
    cast(date_key as integer) as date_key,
    cast(day_type as varchar) as day_type,
    cast(is_planned_change as boolean) as is_planned_change,
    cast(planned_change_lines as bigint) as planned_change_lines,
    cast(planned_change_label as varchar) as planned_change_label,
    cast(measure as varchar) as measure,
    cast(unit as varchar) as unit,
    cast(value as double) as value,
    cast(numerator as double) as numerator,
    cast(denominator as double) as denominator,
    cast(coalesce(typical_days, 0) as bigint) as typical_days,
    -- typical guard: fewer than var('typical_min_days') clean comparable earlier days is too thin
    -- for a typical value; the typical values and differences are then null
    cast(coalesce(typical_days, 0) as bigint) as typical_days_n,
    cast(coalesce(typical_days, 0) < {{ var('typical_min_days') }} as boolean) as typical_is_thin,
    cast(typical_first_date as date) as typical_first_date,
    cast(typical_last_date as date) as typical_last_date,
    cast(case when not (coalesce(typical_days, 0) < {{ var('typical_min_days') }}) then typical_median end as double) as typical_median,
    cast(case when not (coalesce(typical_days, 0) < {{ var('typical_min_days') }}) then typical_mean end as double) as typical_mean,
    cast(case when not (coalesce(typical_days, 0) < {{ var('typical_min_days') }}) then typical_p25 end as double) as typical_p25,
    cast(case when not (coalesce(typical_days, 0) < {{ var('typical_min_days') }}) then typical_p75 end as double) as typical_p75,
    cast(case when not (coalesce(typical_days, 0) < {{ var('typical_min_days') }}) then value - typical_median end as double) as diff_vs_median,
    cast(case when not (coalesce(typical_days, 0) < {{ var('typical_min_days') }}) then value - typical_mean end as double) as diff_vs_mean
from typical
