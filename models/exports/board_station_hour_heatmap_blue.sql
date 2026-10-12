{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/station_hour_heatmap_blue.parquet'
    )
}}
-- Board file: station_hour_heatmap.parquet rows for line_id 'Blue' only (see station_heatmap_for_line).

{{ station_heatmap_for_line('Blue') }}
