-- Grain: one row per line scope ('system' or a GTFS route id), service date and service hour.
-- Service hour = hour of the service day in Boston time (0-23, then 24+ after midnight; see the
-- service_hour macro), taken from:
--   trips (late_trips / trips_compared)            the trip's first observed stop (fct_trips)
--   runs (train delay)                              the arrival that ends the run (int_train_runs,
--                                                   compared runs, runs over 30 minutes included)
--   departures (long_gaps / headway_observations)   the departure (fct_trip_stop_events)
-- Typical = the var('typical_days') most recent earlier service dates of the same day type on
-- which the scope had that hour (p25, median, p75, mean and the count of dates). The usual_*
-- flags say whether the day's value is worse (above p75), better (below p25) or about (inside
-- the band) than usual, and need at least var('usual_min_volume') trips, runs or departures in
-- the hour and var('usual_min_typical_days') earlier dates; otherwise 'not_enough_data'.

with trips as (

    select
        route_id,
        service_date,
        {{ service_hour('first_event_local_at', 'service_date') }} as service_hour,
        is_late_trip
    from {{ ref('fct_trips') }}
    where compared_segments > 0

),

runs as (

    select
        route_id,
        service_date,
        {{ service_hour('arrived_at', 'service_date') }} as service_hour,
        positive_excess_seconds,
        net_excess_seconds
    from {{ ref('int_train_runs') }}
    where is_compared

),

departures as (

    select
        route_id,
        service_date,
        {{ service_hour('event_local_at', 'service_date') }} as service_hour,
        is_long_gap
    from {{ ref('fct_trip_stop_events') }}
    where has_headway_comparison

),

trip_hours as (

    {% for scope in ['route_id', "'system'"] %}
        select
            {{ scope }} as scope_id,
            service_date,
            service_hour,
            count(*) as trips_compared,
            count(*) filter (where is_late_trip) as late_trips
        from trips
        group by all
        {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

run_hours as (

    {% for scope in ['route_id', "'system'"] %}
        select
            {{ scope }} as scope_id,
            service_date,
            service_hour,
            count(*) as runs_compared,
            sum(positive_excess_seconds) as positive_seconds,
            sum(net_excess_seconds) as net_seconds
        from runs
        group by all
        {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

departure_hours as (

    {% for scope in ['route_id', "'system'"] %}
        select
            {{ scope }} as scope_id,
            service_date,
            service_hour,
            count(*) as headway_observations,
            count(*) filter (where is_long_gap) as long_gaps
        from departures
        group by all
        {% if not loop.last %}union all{% endif %}
    {% endfor %}

),

cells as (

    select
        coalesce(trip_hours.scope_id, run_hours.scope_id, departure_hours.scope_id) as scope_id,
        coalesce(trip_hours.service_date, run_hours.service_date, departure_hours.service_date)
            as service_date,
        coalesce(trip_hours.service_hour, run_hours.service_hour, departure_hours.service_hour)
            as service_hour,
        coalesce(trip_hours.trips_compared, 0) as trips_compared,
        coalesce(trip_hours.late_trips, 0) as late_trips,
        coalesce(run_hours.runs_compared, 0) as runs_compared,
        coalesce(run_hours.positive_seconds, 0) as positive_seconds,
        coalesce(run_hours.net_seconds, 0) as net_seconds,
        coalesce(departure_hours.headway_observations, 0) as headway_observations,
        coalesce(departure_hours.long_gaps, 0) as long_gaps
    from trip_hours
    full outer join run_hours
        on
            trip_hours.scope_id = run_hours.scope_id
            and trip_hours.service_date = run_hours.service_date
            and trip_hours.service_hour = run_hours.service_hour
    full outer join departure_hours
        on
            coalesce(trip_hours.scope_id, run_hours.scope_id) = departure_hours.scope_id
            and coalesce(trip_hours.service_date, run_hours.service_date) = departure_hours.service_date
            and coalesce(trip_hours.service_hour, run_hours.service_hour) = departure_hours.service_hour

),

rated as (

    select
        cells.*,
        dates.date_key,
        dates.day_type,
        cells.late_trips / nullif(cells.trips_compared, 0) as late_trip_share,
        cells.positive_seconds / nullif(cells.runs_compared, 0) as positive_per_run_seconds,
        cells.net_seconds / nullif(cells.runs_compared, 0) as net_per_run_seconds,
        cells.long_gaps / nullif(cells.headway_observations, 0) as long_gap_share
    from cells
    inner join {{ ref('dim_dates') }} as dates on cells.service_date = dates.date_day

),

typical as (

    select
        rated.*,
        count(*) over typical_frame as typical_days,
    {% for m in ['late_trip_share', 'positive_per_run_seconds', 'long_gap_share', 'positive_seconds'] %}
        count(rated.{{ m }}) over typical_frame as typical_days_{{ m }},
        quantile_cont(rated.{{ m }}, 0.25) over typical_frame as typical_p25_{{ m }},
        median(rated.{{ m }}) over typical_frame as typical_median_{{ m }},
        quantile_cont(rated.{{ m }}, 0.75) over typical_frame as typical_p75_{{ m }},
        avg(rated.{{ m }}) over typical_frame as typical_mean_{{ m }}{{ ',' if not loop.last }}  -- noqa: LT02
    {% endfor %}
    from rated
    window typical_frame as ({{ typical_window('rated.scope_id, rated.service_hour, rated.day_type') }})

)

select
    {{ dbt_utils.generate_surrogate_key(['scope_id', 'service_date', 'service_hour']) }} as line_hour_key,
    cast(scope_id as varchar) as scope_id,
    cast(service_date as date) as service_date,
    cast(date_key as integer) as date_key,
    cast(day_type as varchar) as day_type,
    cast(service_hour as integer) as service_hour,
    cast(trips_compared as bigint) as trips_compared,
    cast(late_trips as bigint) as late_trips,
    cast(late_trip_share as double) as late_trip_share,
    cast(runs_compared as bigint) as runs_compared,
    cast(positive_seconds as double) as train_delay_positive_seconds,
    cast(net_seconds as double) as train_delay_net_seconds,
    cast(positive_per_run_seconds as double) as train_delay_positive_per_run_seconds,
    cast(net_per_run_seconds as double) as train_delay_net_per_run_seconds,
    cast(headway_observations as bigint) as headway_observations,
    cast(long_gaps as bigint) as long_gaps,
    cast(long_gap_share as double) as long_gap_share,
    cast(typical_days as bigint) as typical_days,
    {% for m, out in [
        ('late_trip_share', 'late_trip_share'),
        ('positive_per_run_seconds', 'train_delay_positive_per_run_seconds'),
        ('long_gap_share', 'long_gap_share'),
        ('positive_seconds', 'train_delay_positive_seconds')
    ] %}
        cast(typical_days_{{ m }} as bigint) as typical_days_{{ out }},
        cast(typical_p25_{{ m }} as double) as typical_p25_{{ out }},
        cast(typical_median_{{ m }} as double) as typical_median_{{ out }},
        cast(typical_p75_{{ m }} as double) as typical_p75_{{ out }},
        cast(typical_mean_{{ m }} as double) as typical_mean_{{ out }},
    {% endfor %}
    cast({{ usual_flag('late_trip_share', 'typical_p25_late_trip_share', 'typical_p75_late_trip_share',
        'trips_compared', 'typical_days_late_trip_share') }} as varchar) as usual_late_trip_share,
    cast({{ usual_flag('positive_per_run_seconds', 'typical_p25_positive_per_run_seconds',
        'typical_p75_positive_per_run_seconds', 'runs_compared', 'typical_days_positive_per_run_seconds') }} as varchar)
        as usual_train_delay_per_run,
    cast({{ usual_flag('long_gap_share', 'typical_p25_long_gap_share', 'typical_p75_long_gap_share',
        'headway_observations', 'typical_days_long_gap_share') }} as varchar) as usual_long_gap_share
from typical
