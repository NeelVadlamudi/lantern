{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/station_hour_heatmap_mattapan.parquet'
    )
}}
-- Board file: board_station_hour_heatmap rows for line_id 'Mattapan' only (see station_heatmap_for_line).

{{ station_heatmap_for_line('Mattapan') }}
