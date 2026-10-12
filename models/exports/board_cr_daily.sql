{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/cr_daily.parquet'
    )
}}
-- Board file: mart_cr_daily, every column (see that model for grain and rules).

select *
from {{ ref('mart_cr_daily') }}
