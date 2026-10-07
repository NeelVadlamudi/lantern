{#-
    Custom generic test: within each partition, `column_name` must run 1, 2, 3 ... n with no gaps
    and no repeats. Fails one row per broken partition.

    Usage:
      columns:
        - name: stop_order
          data_tests:
            - contiguous_sequence:
                arguments:
                  partition_by: [route_id, branch_route_id, direction_id]
-#}
{% test contiguous_sequence(model, column_name, partition_by) %}

with seq as (

    select
        {{ partition_by | join(', ') }},
        count(*) as n_rows,
        count(distinct {{ column_name }}) as n_distinct,
        min({{ column_name }}) as min_value,
        max({{ column_name }}) as max_value
    from {{ model }}
    group by {{ partition_by | join(', ') }}

)

select *
from seq
where min_value != 1
   or max_value != n_rows
   or n_distinct != n_rows

{% endtest %}
