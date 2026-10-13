-- The MBTA reference values on the late tile and in board_data.json come from the seed: target
-- 0.90 and the 2024 result 0.828 (Service Delivery Policy annual report, Fall 2024).
with seed as (
    select
        max(value) filter (where reference_id = 'mbta_rapid_transit_reliability_target') as target_value,
        max(value) filter (where reference_id = 'mbta_rapid_transit_reliability_2024') as result_2024_value
    from {{ ref('board_reference_values') }}
)

select 'late tile reference' as check_name
from {{ ref('board_tiles') }} as tiles
cross join seed
where
    tiles.tile_id = 'late_trip_share'
    and (
        cast(tiles.tile -> 'mbta_reference' ->> 'target_value' as double) is distinct from seed.target_value
        or cast(
            tiles.tile -> 'mbta_reference' ->> 'result_2024_value' as double
        ) is distinct from seed.result_2024_value
    )

union all

select 'seed values' as check_name
from seed
where seed.target_value != 0.90 or seed.result_2024_value != 0.828
