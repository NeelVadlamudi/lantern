{% macro typical_window(partition_by, order_by='service_date') -%}
    {#- Window frame for "typical": the var('typical_days') most recent earlier rows of the same
        partition (the partition always includes day_type), not counting the row itself. -#}
    partition by {{ partition_by }}
    order by {{ order_by }}
    rows between {{ var('typical_days') }} preceding and 1 preceding
{%- endmacro %}

{% macro usual_flag(value, p25, p75, volume, typical_days) -%}
    {#- worse / about / better than usual: outside the typical p25-p75 band, only with enough
        volume on the day and enough earlier dates; otherwise 'not_enough_data'.
        Higher values are worse for every measure this is used on. -#}
    case
        when {{ value }} is null or {{ p25 }} is null
            or coalesce({{ volume }}, 0) < {{ var('usual_min_volume') }}
            or coalesce({{ typical_days }}, 0) < {{ var('usual_min_typical_days') }}
            then 'not_enough_data'
        when {{ value }} > {{ p75 }} then 'worse'
        when {{ value }} < {{ p25 }} then 'better'
        else 'about'
    end
{%- endmacro %}
