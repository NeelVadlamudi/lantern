{#- Local (Boston) wall-clock time for a timestamptz column. -#}
{% macro to_boston_time(column) -%}
    timezone('America/New_York', {{ column }})
{%- endmacro %}

{#- weekday / saturday / sunday / holiday. Holidays from the seed get their own type because the
    MBTA runs a Saturday or Sunday schedule on most of them, so they don't compare to weekdays. -#}
{% macro day_type(date_column) -%}
    case
        when {{ date_column }} in (select holiday_date from {{ ref('holidays') }}) then 'holiday'
        when dayofweek({{ date_column }}) = 6 then 'saturday'
        when dayofweek({{ date_column }}) = 0 then 'sunday'
        else 'weekday'
    end
{%- endmacro %}

{#- GTFS "as of" date used to pick one schedule version for dimensions.
    Defaults to the latest loaded service date; override with --vars '{gtfs_as_of: 20260801}'. -#}
{% macro gtfs_as_of_date() -%}
    {%- if var('gtfs_as_of', '') | string | length > 0 -%}
        strptime('{{ var("gtfs_as_of") }}', '%Y%m%d')::date
    {%- else -%}
        (select max(service_date) from {{ ref('stg_lamp__subway_trip_stops') }})
    {%- endif -%}
{%- endmacro %}

{#- Safe ratio that returns null instead of dividing by zero. -#}
{% macro safe_ratio(numerator, denominator) -%}
    ({{ numerator }})::double / nullif(({{ denominator }})::double, 0)
{%- endmacro %}

{#- Round a DOUBLE for display in board_data.json. DuckDB's round() scales by 10^n first, which
    can push a value like -27.45 (stored as -27.4499...) across the half; formatting with printf
    rounds the stored value exactly, the same way the board's numbers have always been rounded. -#}
{% macro board_round(column, digits) -%}
    cast(printf('%.{{ digits }}f', {{ column }}) as double)
{%- endmacro %}
