-- Stations listed as having no gated-entry data are place-* ids with no rider rows.
with listed as (
    select
        unnest(cast(json_extract(coverage, '$.stations_without_gated_entries.station_ids') as varchar[]))
            as station_id
    from {{ ref('board_payload') }}
)

select listed.station_id
from listed
where
    listed.station_id not like 'place-%'
    or listed.station_id in (select riders.station_id from {{ ref('int_station_period_riders') }} as riders)
