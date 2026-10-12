{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/delay_histogram.parquet'
    )
}}
-- Board file for the delay histogram (mart_delay_histogram): 1-minute bins of per-trip excess
-- (kind 'trip') and per-run excess (kind 'run'), per scope and service date. The lowest and
-- highest bins are open ('under -15 min', '30 min or more'); only bins with observations are
-- stored, and observations over all bins equal total_observations.
-- The hash surrogate key is left out of the file; the grain columns identify each row.

select * exclude (histogram_bin_key)
from {{ ref('mart_delay_histogram') }}
order by kind, scope_id, service_date, bin_minute
