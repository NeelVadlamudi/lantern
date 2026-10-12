-- Grain: one row per station, line (trunk line_id), service date and service hour.
-- Service hour = hour of the service day in Boston time (0-23, then 24+ after midnight), from:
--   runs (train delay)                              the arrival at this station that ends the run
--                                                   (int_train_runs, compared runs, runs over
--                                                   30 minutes included)
--   departures (long_gaps / headway_observations)   the departure from this station
--                                                   (fct_trip_stop_events)
-- Typical and the usual_* flags follow mart_line_hour_heatmap: the var('typical_days') most
-- recent earlier service dates of the same day type with that station, line and hour; worse
-- above the typical p75, better below p25, about inside; 'not_enough_data' below
-- var('usual_min_volume') runs or departures or var('usual_min_typical_days') earlier dates.

with runs as (

    select
        to_station_id as station_id,
        line_id,
        service_date,
        {{ service_hour('arrived_at', 'service_date') }} as service_hour,
        count(*) as runs_compared,
        sum(positive_excess_seconds) as positive_seconds,
        sum(net_excess_seconds) as net_seconds
    from {{ ref('int_train_runs') }}
    where is_compared
    group by all

),

departures as (

    select
        station_id,
        line_id,
        service_date,
        {{ service_hour('event_local_at', 'service_date') }} as service_hour,
        count(*) as headway_observations,
        count(*) filter (where is_long_gap) as long_gaps
    from {{ ref('fct_trip_stop_events') }}
    where has_headway_comparison
    group by all

),

cells as (

    select
        coalesce(runs.station_id, departures.station_id) as station_id,
        coalesce(runs.line_id, departures.line_id) as line_id,
        coalesce(runs.service_date, departures.service_date) as service_date,
        coalesce(runs.service_hour, departures.service_hour) as service_hour,
        coalesce(runs.runs_compared, 0) as runs_compared,
        coalesce(runs.positive_seconds, 0) as positive_seconds,
        coalesce(runs.net_seconds, 0) as net_seconds,
        coalesce(departures.headway_observations, 0) as headway_observations,
        coalesce(departures.long_gaps, 0) as long_gaps
    from runs
    full outer join departures
        on
            runs.station_id = departures.station_id
            and runs.line_id = departures.line_id
            and runs.service_date = departures.service_date
            and runs.service_hour = departures.service_hour

),

rated as (

    select
        cells.*,
        dates.date_key,
        dates.day_type,
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
    {% for m in ['positive_per_run_seconds', 'long_gap_share', 'positive_seconds'] %}
        count(rated.{{ m }}) over typical_frame as typical_days_{{ m }},
        quantile_cont(rated.{{ m }}, 0.25) over typical_frame as typical_p25_{{ m }},
        median(rated.{{ m }}) over typical_frame as typical_median_{{ m }},
        quantile_cont(rated.{{ m }}, 0.75) over typical_frame as typical_p75_{{ m }},
        avg(rated.{{ m }}) over typical_frame as typical_mean_{{ m }}{{ ',' if not loop.last }}  -- noqa: LT02
    {% endfor %}
    from rated
    window typical_frame as (
        {{ typical_window('rated.station_id, rated.line_id, rated.service_hour, rated.day_type') }}
    )

)

select
    {{ dbt_utils.generate_surrogate_key(['station_id', 'line_id', 'service_date', 'service_hour']) }}
        as station_hour_key,
    cast(station_id as varchar) as station_id,
    cast(line_id as varchar) as line_id,
    cast(service_date as date) as service_date,
    cast(date_key as integer) as date_key,
    cast(day_type as varchar) as day_type,
    cast(service_hour as integer) as service_hour,
    cast(runs_compared as bigint) as runs_compared,
    cast(positive_seconds as double) as train_delay_positive_seconds,
    cast(net_seconds as double) as train_delay_net_seconds,
    cast(positive_per_run_seconds as double) as train_delay_positive_per_run_seconds,
    cast(net_per_run_seconds as double) as train_delay_net_per_run_seconds,
    cast(headway_observations as bigint) as headway_observations,
    cast(long_gaps as bigint) as long_gaps,
    cast(long_gap_share as double) as long_gap_share,
    cast(typical_days as bigint) as typical_days,
    {% for m, out in [('positive_per_run_seconds', 'train_delay_positive_per_run_seconds'),
        ('long_gap_share', 'long_gap_share'), ('positive_seconds', 'train_delay_positive_seconds')] %}
        cast(typical_days_{{ m }} as bigint) as typical_days_{{ out }},
        cast(typical_p25_{{ m }} as double) as typical_p25_{{ out }},
        cast(typical_median_{{ m }} as double) as typical_median_{{ out }},
        cast(typical_p75_{{ m }} as double) as typical_p75_{{ out }},
        cast(typical_mean_{{ m }} as double) as typical_mean_{{ out }},
    {% endfor %}
    cast(
        {{ usual_flag('positive_per_run_seconds', 'typical_p25_positive_per_run_seconds',
        'typical_p75_positive_per_run_seconds', 'runs_compared', 'typical_days_positive_per_run_seconds') }}
        as varchar
    ) as usual_train_delay_per_run,
    cast({{ usual_flag('long_gap_share', 'typical_p25_long_gap_share', 'typical_p75_long_gap_share',
        'headway_observations', 'typical_days_long_gap_share') }} as varchar) as usual_long_gap_share
from typical
