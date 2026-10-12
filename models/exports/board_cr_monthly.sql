{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/cr_monthly.parquet'
    )
}}
-- Board file: mart_cr_monthly, every column except its hash surrogate key (the grain columns identify each
-- row; see that model for grain and rules).

select * exclude (cr_scope_month_key)
from {{ ref('mart_cr_monthly') }}
