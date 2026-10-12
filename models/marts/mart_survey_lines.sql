-- Grain: one row per line scope, measure and category of the MBTA 2025 System-Wide Passenger
-- Survey (survey_label '2025 survey'). Scopes: the subway line totals (Red, Orange, Blue, Green,
-- Mattapan; the survey has no Green Line branch totals and Silver Line is left out), the 12
-- Commuter Rail lines (by GTFS route id) and all Commuter Rail ('commuter_rail'). Names are
-- mapped in seeds/line_name_map.csv. weighted_share and margin_of_error are as published (0 to
-- 1); respondents (n) is the number asked the question.

with survey as (

    select
        *,
        case when service_mode = 'Commuter Rail' then reporting_group else service_mode end as source_name
    from {{ ref('stg_mbta__passenger_survey') }}
    where
        (aggregation_level = 'Rapid Transit or Bus Rapid Transit Line' and service_mode not like '%Silver Line%')
        or (service_mode = 'Commuter Rail' and aggregation_level in ('Reporting Group', 'Service Mode'))

)

select
    {{ dbt_utils.generate_surrogate_key(['map.source_name', 'survey.measure', 'survey.category']) }}
        as survey_line_key,
    cast(coalesce(map.route_id, map.line_id, 'commuter_rail') as varchar) as scope_id,
    cast(map.mode as varchar) as mode,
    cast(map.route_id as varchar) as route_id,
    cast(map.line_id as varchar) as line_id,
    cast(survey.source_name as varchar) as survey_line_name,
    cast(survey.measure_group as varchar) as measure_group,
    cast(survey.measure as varchar) as measure,
    cast(survey.category as varchar) as category,
    cast(survey.weighted_share as double) as weighted_share,
    cast(survey.respondents as bigint) as respondents,
    cast(survey.margin_of_error as double) as margin_of_error,
    cast('2025 survey' as varchar) as survey_label
from survey
inner join {{ ref('line_name_map') }} as map
    on map.dataset = 'survey' and survey.source_name = map.source_name
