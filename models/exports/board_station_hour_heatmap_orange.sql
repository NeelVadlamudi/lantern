{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/station_hour_heatmap_orange.parquet'
    )
}}
-- Board file: board_station_hour_heatmap rows for line_id 'Orange' only (see station_heatmap_for_line).

{{ station_heatmap_for_line('Orange') }}
