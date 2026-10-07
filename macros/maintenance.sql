{#- Operations run with `dbt run-operation`. See the README for the command sequences. -#}

{#- Save per-date row counts and loaded_at of the fact before an incremental build. The tests in
    tests/incremental/ (enabled with --vars '{check_incremental: true}') compare against it.

        dbt run-operation save_incremental_state
-#}
{% macro save_incremental_state() %}
    {%- call statement('save_incremental_state') -%}
        create schema if not exists audit;
        create or replace table audit.incremental_state as
        select
            service_date,
            count(*) as n_rows,
            max(loaded_at) as max_loaded_at
        from {{ ref('fct_trip_stop_events') }}
        group by service_date;
    {%- endcall -%}
    {%- do adapter.commit() -%}
    {%- set summary = run_query(
        "select count(*), sum(n_rows), max(service_date) from audit.incremental_state"
    ) -%}
    {%- set row = summary.rows[0] -%}
    {{ print("saved " ~ row[0] ~ " service dates, " ~ row[1] ~ " rows, last " ~ row[2]) }}
{% endmacro %}


{#- Print the GTFS as-of dates (YYYYMMDD) to replay into snap_gtfs_stations, oldest first: the
    first loaded service date, every date inside the loaded window on which a subway station's
    name, rounded coordinates, municipality or wheelchair flag changed, and the last loaded date.
    With reset=true it also drops the snapshot table so the replay starts empty.

        dbt --quiet run-operation station_snapshot_replay_dates --args '{reset: true}'
-#}
{% macro station_snapshot_replay_dates(reset=false) %}
    {%- set sql -%}
        with lamp as (
            select min(service_date) as first_date, max(service_date) as last_date
            from {{ ref('stg_lamp__subway_trip_stops') }}
        ),

        stations as (
            select distinct coalesce(stops.parent_station_id, stop_times.stop_id) as station_id
            from {{ ref('stg_gtfs__stop_times') }} as stop_times
            inner join {{ ref('stg_gtfs__stops') }} as stops
                on stop_times.stop_id = stops.stop_id and stop_times.valid_from_date = stops.valid_from_date
        ),

        versions as (
            select
                stops.stop_id,
                stops.valid_from_date,
                stops.stop_name,
                round(stops.latitude, 5) as lat,
                round(stops.longitude, 5) as lon,
                stops.municipality,
                stops.wheelchair_boarding
            from {{ ref('stg_gtfs__stops') }} as stops
            inner join stations on stops.stop_id = stations.station_id
        ),

        changes as (
            select valid_from_date
            from (
                select
                    *,
                    lag(stop_name) over w as p_name,
                    lag(lat) over w as p_lat,
                    lag(lon) over w as p_lon,
                    lag(municipality) over w as p_muni,
                    lag(wheelchair_boarding) over w as p_wc,
                    row_number() over w as rn
                from versions
                window w as (partition by stop_id order by valid_from_date)
            )
            where rn > 1 and (
                p_name is distinct from stop_name or p_lat is distinct from lat
                or p_lon is distinct from lon or p_muni is distinct from municipality
                or p_wc is distinct from wheelchair_boarding
            )
        )

        select distinct strftime(d, '%Y%m%d') as as_of
        from (
            select first_date as d from lamp
            union all
            select changes.valid_from_date from changes, lamp
            where changes.valid_from_date > lamp.first_date and changes.valid_from_date <= lamp.last_date
            union all
            select last_date from lamp
        )
        order by as_of
    {%- endset -%}
    {%- set dates = run_query(sql).columns[0].values() -%}
    {%- if reset -%}
        {%- set snapshot = graph.nodes['snapshot.' ~ project_name ~ '.snap_gtfs_stations'] -%}
        {%- set existing = adapter.get_relation(snapshot.database, snapshot.schema, snapshot.alias) -%}
        {%- if existing is not none -%}
            {%- do adapter.drop_relation(existing) -%}
            {%- do adapter.commit() -%}
        {%- endif -%}
    {%- endif -%}
    {{ print(dates | join('\n')) }}
{% endmacro %}
