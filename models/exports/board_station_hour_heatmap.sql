{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/station_hour_heatmap.parquet'
    )
}}
-- Board file for the hour x date heatmap per station (mart_station_hour_heatmap). Grain: one row
-- per station, line, service date and service hour. Train delay counts runs arriving at the
-- station; gaps count departures from it. usual_* flags as in line_hour_heatmap.
-- The hash surrogate key is left out of the file; the grain columns identify each row.

select
    heatmap.* exclude (station_hour_key),  -- noqa: RF02
    stations.station_name
from {{ ref('mart_station_hour_heatmap') }} as heatmap
inner join {{ ref('dim_stations') }} as stations on heatmap.station_id = stations.station_id
order by heatmap.station_id, heatmap.line_id, heatmap.service_date, heatmap.service_hour
