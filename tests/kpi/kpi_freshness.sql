-- Freshness tile = last service date in the fact.
with fact as (
    select strftime(max(service_date), '%Y-%m-%d') as last_service_date
    from {{ ref('fct_trip_stop_events') }}
)

select
    tiles.value_text as board_value,
    fact.last_service_date
from {{ ref('board_tiles') }} as tiles
cross join fact
where tiles.tile_id = 'freshness'
    and tiles.value_text is distinct from fact.last_service_date
