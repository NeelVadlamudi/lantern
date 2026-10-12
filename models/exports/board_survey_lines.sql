{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/survey_lines.parquet'
    )
}}
-- Board file: mart_survey_lines, every column except its hash surrogate key (the grain columns
-- identify each row; see that model for grain and rules). Small-n cells are suppressed: when
-- respondents is below var('survey_min_respondents') (30), weighted_share and margin_of_error are
-- set to null and is_suppressed is true. respondents is always kept so the reason is visible.

select
    survey.* exclude (survey_line_key, weighted_share, margin_of_error),  -- noqa: RF02, RF03
    case when survey.respondents >= {{ var('survey_min_respondents') }} then survey.weighted_share end
        as weighted_share,
    case when survey.respondents >= {{ var('survey_min_respondents') }} then survey.margin_of_error end
        as margin_of_error,
    coalesce(survey.respondents < {{ var('survey_min_respondents') }}, true) as is_suppressed,
    {{ var('survey_min_respondents') }} as min_respondents
from {{ ref('mart_survey_lines') }} as survey
