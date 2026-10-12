{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/delay_histogram.parquet'
    )
}}
-- Board file for the delay histogram (mart_delay_histogram): 1-minute bins of per-trip excess
-- (kind 'trip') and per-run excess (kind 'run'), per scope and service date. The lowest and
-- highest bins are open ('under -15 min', '30 min or more'); only bins with observations are
-- stored, and observations over all bins equal total_observations.

select *
from {{ ref('mart_delay_histogram') }}
order by kind, scope_id, service_date, bin_minute
