{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/survey_lines.parquet'
    )
}}
-- Board file: mart_survey_lines, every column except its hash surrogate key (the grain columns identify each
-- row; see that model for grain and rules).

select * exclude (survey_line_key)
from {{ ref('mart_survey_lines') }}
