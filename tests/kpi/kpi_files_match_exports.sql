-- Each Parquet file listed in board_data.json `files` has the row count of the export model
-- that wrote it, and all fifteen export files are listed.
with listed as (
    select
        listed_file ->> 'file' as file_name,
        cast(listed_file ->> 'rows' as bigint) as listed_rows
    from (select unnest(cast(files as json[])) as listed_file from {{ ref('board_payload') }})
),

exported as (
    select
        'line_daily.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_line_daily') }}
    union all
    select
        'line_periods.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_line_periods') }}
    union all
    select
        'station_periods.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_station_periods') }}
    union all
    select
        'station_daily.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_station_daily') }}
    union all
    select
        'map_stations.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_map_stations') }}
    union all
    select
        'line_stops.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_line_stops') }}
    union all
    select
        'line_shapes.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_line_shapes') }}
    union all
    select
        'service_periods.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_service_periods') }}
    union all
    select
        'routes.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_routes') }}
    union all
    select
        'segments.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_segments') }}
    union all
    select
        'rider_time_lost_daily.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_rider_time_lost_daily') }}
    union all
    select
        'rider_time_lost_weekly.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_rider_time_lost_weekly') }}
    union all
    select
        'station_time_lost.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_station_time_lost') }}
    union all
    select
        'station_trend.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_station_trend') }}
    union all
    select
        'line_buffer.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_line_buffer') }}
)

select
    exported.file_name,
    exported.n_rows,
    listed.listed_rows
from exported
left join listed on exported.file_name = listed.file_name
where listed.listed_rows is distinct from exported.n_rows
