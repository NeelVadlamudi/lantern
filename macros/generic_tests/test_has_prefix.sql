{#- Custom generic test: every non-null value must start with `prefix`
    (used to keep station ids in the GTFS parent-station form, place-*). -#}
{% test has_prefix(model, column_name, prefix) %}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and not starts_with({{ column_name }}, '{{ prefix }}')

{% endtest %}
