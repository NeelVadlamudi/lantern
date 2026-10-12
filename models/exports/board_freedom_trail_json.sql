{{
    config(
        location=env_var('MBTA_OUT_DIR', 'out') ~ '/freedom_trail.json',
        format='json',
        options={'array': true}
    )
}}
-- Board file: the same rows and columns as out/freedom_trail.parquet, written as a JSON array
-- for pages that do not load DuckDB-WASM. Grain: one row per Freedom Trail site.

select *
from {{ ref('board_freedom_trail') }}
order by site_order
