{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/cr_daily.parquet'
    )
}}
-- Board file: mart_cr_daily, every column except its hash surrogate key (the grain columns identify each
-- row; see that model for grain and rules).

select * exclude (cr_route_day_key)
from {{ ref('mart_cr_daily') }}
