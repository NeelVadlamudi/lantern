{{ config(severity='warn') }}
-- GTFS archive records whose end date is before their start date never applied to any service
-- date. They are harmless (as-of filters skip them) but are counted here as a source issue.
select
    'stops' as gtfs_file,
    stop_id as record_id,
    valid_from_date,
    valid_to_date
from {{ ref('stg_gtfs__stops') }}
where valid_to_date < valid_from_date

union all

select
    'routes' as gtfs_file,
    route_id as record_id,
    valid_from_date,
    valid_to_date
from {{ ref('stg_gtfs__routes') }}
where valid_to_date < valid_from_date

union all

select
    'route_patterns' as gtfs_file,
    route_pattern_id as record_id,
    valid_from_date,
    valid_to_date
from {{ ref('stg_gtfs__route_patterns') }}
where valid_to_date < valid_from_date
