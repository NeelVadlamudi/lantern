{#- Custom generic test: a share/rate column must be null or between 0 and 1 inclusive. -#}
{% test is_share(model, column_name) %}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and ({{ column_name }} < 0 or {{ column_name }} > 1)

{% endtest %}
