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

{% macro planned_baseline_key(partition_by, flag='is_planned_change', order_by='service_date') -%}
    {#- Ordering key for typical values that skip planned-change days: the running count of
        earlier-or-same rows without a planned change, plus 0.5 on a planned-change row. With
        typical_window_excluding() each row then sees exactly the var('typical_days') most recent
        earlier rows without a planned change (aggregates must ignore planned rows: pass values
        through typical_value()). -#}
    sum(case when {{ flag }} then 0 else 1 end) over (
        partition by {{ partition_by }} order by {{ order_by }}
        rows between unbounded preceding and current row
    ) + case when {{ flag }} then 0.5 else 0 end
{%- endmacro %}

{% macro typical_window_excluding(partition_by, key='baseline_key') -%}
    {#- Frame for typical values without planned-change days (see planned_baseline_key()):
        keys k - typical_days .. k - 0.5, which are the typical_days most recent earlier rows
        without a planned change, and never the row itself. -#}
    partition by {{ partition_by }}
    order by {{ key }}
    range between {{ var('typical_days') }} preceding and 0.5 preceding
{%- endmacro %}

{% macro typical_value(expr, flag='is_planned_change') -%}
    case when not {{ flag }} then {{ expr }} end
{%- endmacro %}
