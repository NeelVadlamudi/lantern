{#-
    URLs of the LAMP subway files that stg_lamp__subway_trip_stops should read, from the LAMP
    index (source lamp.lamp_index; in the daily run a list built by scripts/lamp_manifest.py,
    from index.csv when it is available, else from the daily file names that exist).

    Window end:   var('lamp_end_date'), else the latest file that is a complete service date
                  (yesterday in Boston, since today's file is still being written).
    Window start: incremental run -> latest service date already loaded minus
                  var('incremental_lookback_days') (LAMP republishes recent files), so the
                  lookback dates are re-read and replaced; any older loaded date whose index
                  last_modified is later than when it was loaded (republished after the
                  lookback) is re-read too, and so is any listed date after the first loaded
                  one that has no rows yet (a day MBTA published late is picked up);
                  full refresh   -> var('lamp_start_date'), else end minus
                  var('lamp_window_days') - 1 (default: the last 90 complete dates).

    Files with no rows are not read. MBTA has republished days as empty files (2026-07-16 and
    2026-09-09, on 2026-10-22); delete+insert cannot replace a date with nothing, so the rows
    already loaded for such a date are kept. Every file checked is recorded with its row count
    in lamp_file_reads (see lamp_file_reads_relation()), which the tests use to tell an empty
    republish from a missed one.
-#}
{% macro lamp_files_to_load() %}
    {%- if not execute -%}
        {{ return([]) }}
    {%- endif -%}
    {%- set index -%}
        (
            select
                cast(service_date as date) as service_date,
                file_url,
                cast(cast(last_modified as timestamptz) at time zone 'UTC' as timestamp) as last_modified_utc
            from {{ source('lamp', 'lamp_index') }}
        )
    {%- endset -%}
    {%- if var('lamp_end_date', none) -%}
        {%- set end_sql = "date '" ~ var('lamp_end_date') ~ "'" -%}
    {%- else -%}
        {%- set end_sql -%}
            least(
                cast(now() at time zone 'America/New_York' as date) - 1,
                (select max(service_date) from {{ index }} as lamp_index)
            )
        {%- endset -%}
    {%- endif -%}
    {%- if is_incremental() -%}
        {%- set start_sql -%}
            (select max(service_date) - {{ var('incremental_lookback_days') }} from {{ this }})
        {%- endset -%}
    {%- elif var('lamp_start_date', none) -%}
        {%- set start_sql = "date '" ~ var('lamp_start_date') ~ "'" -%}
    {%- else -%}
        {%- set start_sql = end_sql ~ " - " ~ (var('lamp_window_days') - 1) -%}
    {%- endif -%}
    {%- if is_incremental() -%}
        {%- set republished_sql -%}
            or (
                lamp_index.service_date <= {{ end_sql }}
                and lamp_index.service_date in (
                    select loaded.service_date
                    from (
                        select service_date, max(_loaded_at) as loaded_at from {{ this }} group by service_date
                    ) as loaded
                    inner join {{ index }} as republished on loaded.service_date = republished.service_date
                    where republished.last_modified_utc > loaded.loaded_at
                )
            )
            or (
                lamp_index.service_date between (select min(service_date) from {{ this }}) and {{ end_sql }}
                and lamp_index.service_date not in (select distinct service_date from {{ this }})
            )
        {%- endset -%}
    {%- else -%}
        {%- set republished_sql = '' -%}
    {%- endif -%}
    {%- set query -%}
        select file_url, cast(service_date as varchar), cast(last_modified_utc as varchar)
        from {{ index }} as lamp_index
        where service_date between {{ start_sql }} and {{ end_sql }} {{ republished_sql }}
        order by service_date
    {%- endset -%}
    {%- set candidates = run_query(query).rows -%}
    {%- if candidates | length == 0 -%}
        {{ log("LAMP files to read: 0", info=true) }}
        {{ return([]) }}
    {%- endif -%}
    {%- set url_list = [] -%}
    {%- for row in candidates -%}{%- do url_list.append(row[0]) -%}{%- endfor -%}
    {%- set counts_query -%}
        select file_name, num_rows from parquet_file_metadata(['{{ url_list | join("', '") }}'])
    {%- endset -%}
    {%- set num_rows = {} -%}
    {%- for row in run_query(counts_query).rows -%}{%- do num_rows.update({row[0]: row[1]}) -%}{%- endfor -%}
    {%- set log_rel = lamp_file_reads_relation() -%}
    {%- set values = [] -%}
    {%- set urls = [] -%}
    {%- set empty = [] -%}
    {%- for row in candidates -%}
        {%- set n = num_rows.get(row[0], 0) | int -%}
        {%- do values.append("(date '" ~ row[1] ~ "', " ~ ("timestamp '" ~ row[2] ~ "'" if row[2] else "null")
            ~ ", '" ~ row[0] ~ "', " ~ n ~ ", current_timestamp at time zone 'UTC')") -%}
        {%- if n > 0 -%}{%- do urls.append(row[0]) -%}{%- else -%}{%- do empty.append(row[1]) -%}{%- endif -%}
    {%- endfor -%}
    {%- call statement('log_lamp_file_reads') -%}
        create schema if not exists {{ log_rel.schema }};
        create table if not exists {{ log_rel }} (
            service_date date, last_modified_utc timestamp, file_url varchar, num_rows bigint, checked_at timestamp
        );
        insert into {{ log_rel }} values {{ values | join(', ') }};
    {%- endcall -%}
    {%- if empty | length > 0 -%}
        {{ log("LAMP files with no rows, not read (rows already loaded are kept): " ~ (empty | join(', ')), info=true) }}
    {%- endif -%}
    {{ log("LAMP files to read: " ~ (urls | length), info=true) }}
    {{ return(urls) }}
{% endmacro %}

{#- Where lamp_files_to_load() records each file it checked (service date, last_modified, row count). -#}
{% macro lamp_file_reads_relation() %}
    {{ return(api.Relation.create(database=target.database, schema='staging', identifier='lamp_file_reads')) }}
{% endmacro %}

{#- Select of (service_date, last_modified_utc) for the LAMP file versions that were checked and
    held no rows. Empty (no rows) when nothing has been recorded yet. -#}
{% macro lamp_empty_file_versions() %}
    {%- set rel = lamp_file_reads_relation() -%}
    {%- if execute and adapter.get_relation(database=rel.database, schema=rel.schema, identifier=rel.identifier) -%}
        (select distinct service_date, last_modified_utc from {{ rel }} where num_rows = 0)
    {%- else -%}
        (select cast(null as date) as service_date, cast(null as timestamp) as last_modified_utc where false)
    {%- endif -%}
{% endmacro %}

{#- Keep a reference table between builds; re-read its remote source only on the first build,
    on --full-refresh, or with --vars '{refresh_reference: true}'. Used as the pre_hook of the
    GTFS and Open Data staging tables, which are too large to download on every build. -#}
{# keep_reference_tables lists staging models to leave as cached even when refresh_reference
   is set (the daily run uses it when an Open Data download failed). #}
{% macro refresh_this_reference() %}
    {{ return(var('refresh_reference', false) and this.name not in var('keep_reference_tables', [])) }}
{% endmacro %}

{% macro clear_reference_table() %}
    {%- if is_incremental() and refresh_this_reference() -%}
        delete from {{ this }}
    {%- else -%}
        select 1
    {%- endif -%}
{% endmacro %}

{% macro keep_reference_table() %}
    {{ return(is_incremental() and not refresh_this_reference()) }}
{% endmacro %}
