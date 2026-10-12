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
-- Shares and per-run values are the day's own ratio (numerator / denominator, both given); the
-- typical value is the median or mean of the earlier days' ratios.

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
        long_gaps,
        headway_observations
    from {{ ref('mart_line_daily_reliability') }}

    union all

    select
        'system' as scope_id,
        service_date,
        sum(late_trips) as late_trips,
        sum(trips_compared) as trips_compared,
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
        sum(long_gaps) as long_gaps,
        sum(headway_observations) as headway_observations
    from {{ ref('mart_line_daily_reliability') }}
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
        dates.day_type
    from measures
    inner join {{ ref('dim_dates') }} as dates on measures.service_date = dates.date_day

),

typical as (

    select
        typed.*,
        median(typed.value) over typical_frame as typical_median,
        avg(typed.value) over typical_frame as typical_mean,
        quantile_cont(typed.value, 0.25) over typical_frame as typical_p25,
        quantile_cont(typed.value, 0.75) over typical_frame as typical_p75,
        count(typed.value) over typical_frame as typical_days,
        min(typed.service_date) over typical_frame as typical_first_date,
        max(typed.service_date) over typical_frame as typical_last_date
    from typed
    window typical_frame as ({{ typical_window('typed.scope_id, typed.measure, typed.day_type') }})

)

select
    {{ dbt_utils.generate_surrogate_key(['scope_id', 'service_date', 'measure']) }} as line_day_measure_key,
    cast(scope_id as varchar) as scope_id,
    cast(service_date as date) as service_date,
    cast(date_key as integer) as date_key,
    cast(day_type as varchar) as day_type,
    cast(measure as varchar) as measure,
    cast(unit as varchar) as unit,
    cast(value as double) as value,
    cast(numerator as double) as numerator,
    cast(denominator as double) as denominator,
    cast(typical_days as bigint) as typical_days,
    cast(typical_first_date as date) as typical_first_date,
    cast(typical_last_date as date) as typical_last_date,
    cast(typical_median as double) as typical_median,
    cast(typical_mean as double) as typical_mean,
    cast(typical_p25 as double) as typical_p25,
    cast(typical_p75 as double) as typical_p75,
    cast(value - typical_median as double) as diff_vs_median,
    cast(value - typical_mean as double) as diff_vs_mean
from typical
