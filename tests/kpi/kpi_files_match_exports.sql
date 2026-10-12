-- Each Parquet file listed in board_data.json `files` has the row count of the export model
-- that wrote it, and every export file is listed.
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
    union all
    select
        'train_delay_daily.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_train_delay_daily') }}
    union all
    select
        'suspension_gaps.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_suspension_gaps') }}
    union all
    select
        'line_day_metrics.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_line_day_metrics') }}
    union all
    select
        'day_worst_segments.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_day_worst_segments') }}
    union all
    select
        'day_worst_stations.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_day_worst_stations') }}
    union all
    select
        'line_hour_heatmap.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_line_hour_heatmap') }}
    union all
    select
        'station_hour_heatmap.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_station_hour_heatmap') }}
    union all
    select
        'delay_histogram.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_delay_histogram') }}
    union all
    select
        'train_delay_by_line.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_train_delay_by_line') }}
    union all
    select
        'cr_daily.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_cr_daily') }}
    union all
    select
        'cr_monthly.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_cr_monthly') }}
    union all
    select
        'survey_lines.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_survey_lines') }}
    union all
    select
        'freedom_trail.parquet' as file_name,
        count(*) as n_rows
    from {{ ref('board_freedom_trail') }}
)

select
    exported.file_name,
    exported.n_rows,
    listed.listed_rows
from exported
left join listed on exported.file_name = listed.file_name
where listed.listed_rows is distinct from exported.n_rows
