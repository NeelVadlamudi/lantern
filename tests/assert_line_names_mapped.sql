-- Every line name in the Commuter Rail files and the passenger survey rows the board uses has a
-- row in seeds/line_name_map.csv, and for the reliability file the mapped route id equals the
-- route id the file gives.
with reliability as (
    select distinct
        rel.source_line_name,
        rel.source_route_id,
        map.route_id
    from {{ ref('stg_mbta__cr_reliability') }} as rel
    left join {{ ref('line_name_map') }} as map
        on map.dataset = 'cr_reliability' and rel.source_line_name = map.source_name
),

boardings as (
    select distinct
        board.source_line_name,
        map.route_id
    from {{ ref('stg_mbta__cr_boardings') }} as board
    left join {{ ref('line_name_map') }} as map
        on map.dataset = 'cr_boardings' and board.source_line_name = map.source_name
),

survey_names as (
    select distinct case when service_mode = 'Commuter Rail' then reporting_group else service_mode end as source_name
    from {{ ref('stg_mbta__passenger_survey') }}
    where
        (aggregation_level = 'Rapid Transit or Bus Rapid Transit Line' and service_mode not like '%Silver Line%')
        or (service_mode = 'Commuter Rail' and aggregation_level in ('Reporting Group', 'Service Mode'))
)

select
    'cr_reliability' as dataset,
    source_line_name as source_name
from reliability
where route_id is null or route_id != source_route_id

union all

select
    'cr_boardings' as dataset,
    source_line_name as source_name
from boardings
where route_id is null

union all

select
    'survey' as dataset,
    survey_names.source_name
from survey_names
left join {{ ref('line_name_map') }} as map
    on map.dataset = 'survey' and survey_names.source_name = map.source_name
where map.source_name is null
