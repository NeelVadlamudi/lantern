{#-
    URLs of the LAMP subway files that stg_lamp__subway_trip_stops should read, from the LAMP
    index (source lamp.lamp_index).

    Window end:   var('lamp_end_date'), else the latest file that is a complete service date
                  (yesterday in Boston, since today's file is still being written).
    Window start: incremental run -> latest service date already loaded minus
                  var('incremental_lookback_days') (LAMP republishes recent files), so the
                  lookback dates are re-read and replaced;
                  full refresh   -> var('lamp_start_date'), else end minus
                  var('lamp_window_days') - 1 (default: the last 90 complete dates).
-#}
{% macro lamp_files_to_load() %}
    {%- if not execute -%}
        {{ return([]) }}
    {%- endif -%}
    {%- set index -%}
        (select cast(service_date as date) as service_date, file_url from {{ source('lamp', 'lamp_index') }})
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
    {%- set query -%}
        select file_url
        from {{ index }} as lamp_index
        where service_date between {{ start_sql }} and {{ end_sql }}
        order by service_date
    {%- endset -%}
    {%- set urls = run_query(query).columns[0].values() | list -%}
    {{ log("LAMP files to read: " ~ (urls | length), info=true) }}
    {{ return(urls) }}
{% endmacro %}

{#- Keep a reference table between builds; re-read its remote source only on the first build,
    on --full-refresh, or with --vars '{refresh_reference: true}'. Used as the pre_hook of the
    GTFS and Open Data staging tables, which are too large to download on every build. -#}
{% macro clear_reference_table() %}
    {%- if is_incremental() and var('refresh_reference', false) -%}
        delete from {{ this }}
    {%- else -%}
        select 1
    {%- endif -%}
{% endmacro %}

{% macro keep_reference_table() %}
    {{ return(is_incremental() and not var('refresh_reference', false)) }}
{% endmacro %}
