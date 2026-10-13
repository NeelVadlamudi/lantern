-- Every exported board file with a service_date covers at most var('reporting_window_days')
-- (90) calendar dates, ending on the latest loaded date: the daily build rolls the window
-- forward and never grows it, whatever older dates the incremental facts keep. The Commuter
-- Rail reliability files (board_cr_*) are the MBTA's own monthly history since 2016 and are
-- not part of the subway window.
{%- set exports = [
    'board_day_worst_segments', 'board_day_worst_stations', 'board_delay_histogram',
    'board_headway_adherence', 'board_line_daily', 'board_line_day_completeness', 'board_line_day_metrics',
    'board_line_hour_heatmap', 'board_rider_time_lost_daily', 'board_service_changes', 'board_station_daily',
    'board_station_hour_heatmap', 'board_suspension_gaps', 'board_train_delay_by_line',
    'board_train_delay_daily'
] %}

with spans as (
    {% for name in exports %}
        select
            '{{ name }}' as model_name,
            min(service_date) as first_date,
            max(service_date) as last_date
        from {{ ref(name) }}
        {% if not loop.last %}union all{% endif %}
    {% endfor %}
)

select *
from spans
where datediff('day', first_date, last_date) + 1 > {{ var('reporting_window_days') }}
