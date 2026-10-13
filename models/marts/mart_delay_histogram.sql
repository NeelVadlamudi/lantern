-- Grain: one row per measure kind, line scope ('system' or a GTFS route id), service date and
-- 1-minute bin that has at least one observation (empty bins are not stored; their count is 0).
-- kind 'trip': trip excess of each compared matched trip (fct_trips.trip_excess_seconds, runs over 30
--              minutes included).
-- kind 'run':  net excess of each compared stop-to-stop run (int_train_runs).
-- Bins are [k, k+1) minutes from var('histogram_min_minutes') (-15) to var('histogram_max_minutes')
-- (30). Values below the first bin go to one open bin ('under -15 min'), values at or above the
-- last to one open top bin ('30 min or more'); nothing is dropped, and excess_seconds_sum keeps
-- the exact total of each bin. observations / total_observations = share of the day's trips or
-- runs in the bin.

with observations as (

    select
        'trip' as kind,
        route_id,
        service_date,
        cast(trip_excess_seconds as double) as excess_seconds
    from {{ ref('fct_trips') }}
    where compared_segments > 0 and is_matched_trip

    union all

    select
        'run' as kind,
        route_id,
        service_date,
        cast(net_excess_seconds as double) as excess_seconds
    from {{ ref('int_train_runs') }}
    where is_compared

),

binned as (

    select
        kind,
        route_id,
        service_date,
        excess_seconds,
        case
            when excess_seconds < {{ var('histogram_min_minutes') }} * 60
                then {{ var('histogram_min_minutes') }} - 1
            when excess_seconds >= {{ var('histogram_max_minutes') }} * 60
                then {{ var('histogram_max_minutes') }}
            else cast(floor(excess_seconds / 60) as integer)
        end as bin_minute
    from observations

),

scoped as (

    {% for scope in ['route_id', "'system'"] %}
        select
            kind,
            {{ scope }} as scope_id,
            service_date,
            bin_minute,
            count(*) as observations,
            sum(excess_seconds) as excess_seconds_sum
        from binned
        group by all
        {% if not loop.last %}union all{% endif %}
    {% endfor %}

)

select
    {{ dbt_utils.generate_surrogate_key([
        'scoped.kind', 'scoped.scope_id', 'scoped.service_date', 'scoped.bin_minute'
    ]) }}
        as histogram_bin_key,
    cast(scoped.kind as varchar) as kind,
    cast(scoped.scope_id as varchar) as scope_id,
    cast(scoped.service_date as date) as service_date,
    cast(dates.date_key as integer) as date_key,
    cast(dates.day_type as varchar) as day_type,
    cast(scoped.bin_minute as integer) as bin_minute,
    cast(case when scoped.bin_minute >= {{ var('histogram_min_minutes') }} then scoped.bin_minute * 60 end as integer)
        as bin_start_seconds,
    cast(
        case
            when scoped.bin_minute < {{ var('histogram_max_minutes') }} then (scoped.bin_minute + 1) * 60
        end as integer
    )
        as bin_end_seconds,
    cast(
        scoped.bin_minute < {{ var('histogram_min_minutes') }}
        or scoped.bin_minute >= {{ var('histogram_max_minutes') }} as boolean
    ) as is_open_bin,
    cast(case
        when scoped.bin_minute < {{ var('histogram_min_minutes') }}
            then 'under {{ var("histogram_min_minutes") }} min'
        when scoped.bin_minute >= {{ var('histogram_max_minutes') }}
            then '{{ var("histogram_max_minutes") }} min or more'
        else scoped.bin_minute || ' to ' || (scoped.bin_minute + 1) || ' min'
    end as varchar) as bin_label,
    cast(scoped.observations as bigint) as observations,
    cast(scoped.excess_seconds_sum as double) as excess_seconds_sum,
    cast(sum(scoped.observations) over (partition by scoped.kind, scoped.scope_id, scoped.service_date) as bigint)
        as total_observations,
    cast(scoped.observations / sum(scoped.observations) over (
        partition by scoped.kind, scoped.scope_id, scoped.service_date
    ) as double) as share_of_observations
from scoped
inner join {{ ref('dim_dates') }} as dates on scoped.service_date = dates.date_day
