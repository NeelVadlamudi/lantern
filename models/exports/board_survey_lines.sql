{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/survey_lines.parquet'
    )
}}
-- Board file: mart_survey_lines, every column (see that model for grain and rules).

select *
from {{ ref('mart_survey_lines') }}
