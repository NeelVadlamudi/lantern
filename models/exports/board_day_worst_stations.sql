{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/day_worst_stations.parquet'
    )
}}
-- Board file: the 3 stations with the most long gaps between trains each day, per line scope and
-- for the whole subway (mart_station_day_gaps, day_rank 1 to 3; ties by long_gap_share, then
-- station_id), with the station's typical value for the same day type.
-- Grain: one row per scope, service date and rank.

select
    gaps.scope_id,
    gaps.service_date,
    gaps.day_type,
    gaps.day_rank,
    gaps.station_id,
    stations.station_name,
    gaps.headway_observations,
    gaps.long_gaps,
    gaps.long_gap_share,
    gaps.typical_days,
    gaps.typical_median_long_gaps,
    gaps.typical_mean_long_gaps,
    gaps.diff_vs_median_long_gaps,
    gaps.diff_vs_mean_long_gaps,
    gaps.typical_median_long_gap_share,
    gaps.typical_mean_long_gap_share,
    gaps.diff_vs_median_long_gap_share,
    gaps.diff_vs_mean_long_gap_share
from {{ ref('mart_station_day_gaps') }} as gaps
inner join {{ ref('dim_stations') }} as stations on gaps.station_id = stations.station_id
where gaps.day_rank <= 3
order by gaps.service_date, gaps.scope_id, gaps.day_rank
