{% macro service_hour(local_ts, service_date) -%}
    {#- Hour of the service day from a Boston local timestamp: 0-23 on the calendar date of the
        service date, 24 and up after midnight (a 1:30 AM arrival on the next day is hour 25). -#}
    cast(floor((epoch({{ local_ts }}) - epoch(cast({{ service_date }} as timestamp))) / 3600) as integer)
{%- endmacro %}
