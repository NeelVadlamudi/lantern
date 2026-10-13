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

select
    histogram.* exclude (histogram_bin_key),  -- noqa: RF02
    coalesce(planned.is_planned_change, false) as is_planned_change,
    planned.planned_change_label
from {{ ref('mart_delay_histogram') }} as histogram
left join {{ ref('mart_planned_change_scope_days') }} as planned
    on
        planned.scope_type = 'route'
        and histogram.scope_id = planned.scope_id
        and histogram.service_date = planned.service_date
order by histogram.kind, histogram.scope_id, histogram.service_date, histogram.bin_minute
