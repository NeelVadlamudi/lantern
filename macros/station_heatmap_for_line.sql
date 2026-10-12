{#- Body of the per-line station heatmap files (board_station_hour_heatmap_<line>): the same rows
    and columns as board_station_hour_heatmap, for one line_id, so a phone loads only the line
    that is picked. -#}
{% macro station_heatmap_for_line(line_id) %}
select *
from {{ ref('board_station_hour_heatmap') }}
where line_id = '{{ line_id }}'
order by station_id, service_date, service_hour
{% endmacro %}
