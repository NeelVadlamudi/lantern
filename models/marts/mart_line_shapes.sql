-- Grain: one row per branch, direction and point along the track (canonical route pattern).
-- Ordered WGS84 points for drawing each line branch, with the official route color.

select
    {{ dbt_utils.generate_surrogate_key(['shapes.branch_route_id', 'shapes.direction_id', 'shapes.point_order']) }}
        as line_shape_point_key,
    cast(shapes.route_id as varchar) as route_id,
    cast(shapes.branch_route_id as varchar) as branch_route_id,
    cast(shapes.direction_id as integer) as direction_id,
    cast(shapes.shape_id as varchar) as shape_id,
    cast(shapes.point_order as integer) as point_order,
    cast(shapes.longitude as double) as longitude,
    cast(shapes.latitude as double) as latitude,
    cast(routes.route_color_hex as varchar) as route_color_hex
from {{ ref('int_line_shapes') }} as shapes
left join {{ ref('dim_routes') }} as routes
    on shapes.route_id = routes.route_id
