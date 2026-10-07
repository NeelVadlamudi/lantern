{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/service_periods.parquet'
    )
}}
-- Board file: service period labels for the time-of-day strip (dim_service_periods).

select * from {{ ref('dim_service_periods') }}
order by sort_order
