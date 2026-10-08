{{ config(enabled=var('check_build', false), tags=['post_build']) }}
-- out/duration_label_cases.json (written by the on-run-end hook) has exactly the seconds and
-- labels of board_duration_label_cases, in order. Runs after the build, with
-- assert_build_has_no_failures (dbt test --select tag:post_build --vars '{check_build: true}').
{%- set out_dir = env_var('MBTA_OUT_DIR', 'out') %}

with file_cases as (
    select
        row_number() over () as position,
        seconds,
        label
    from read_json('{{ out_dir }}/duration_label_cases.json', format = 'array')
),

model_cases as (
    select
        row_number() over (order by sort_order) as position,
        seconds,
        label
    from {{ ref('board_duration_label_cases') }}
)

select
    model_cases.position,
    model_cases.seconds,
    model_cases.label,
    file_cases.seconds as file_seconds,
    file_cases.label as file_label
from model_cases
full outer join file_cases on model_cases.position = file_cases.position
where
    file_cases.seconds is distinct from model_cases.seconds
    or file_cases.label is distinct from model_cases.label
