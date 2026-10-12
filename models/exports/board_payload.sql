{{ config(materialized='table') }}
-- depends_on: {{ ref('board_line_daily') }}
-- depends_on: {{ ref('board_line_periods') }}
-- depends_on: {{ ref('board_station_periods') }}
-- depends_on: {{ ref('board_station_daily') }}
-- depends_on: {{ ref('board_map_stations') }}
-- depends_on: {{ ref('board_line_stops') }}
-- depends_on: {{ ref('board_line_shapes') }}
-- depends_on: {{ ref('board_service_periods') }}
-- depends_on: {{ ref('board_routes') }}
-- depends_on: {{ ref('board_segments') }}
-- depends_on: {{ ref('board_rider_time_lost_daily') }}
-- depends_on: {{ ref('board_rider_time_lost_weekly') }}
-- depends_on: {{ ref('board_station_time_lost') }}
-- depends_on: {{ ref('board_station_trend') }}
-- depends_on: {{ ref('board_line_buffer') }}
-- depends_on: {{ ref('board_duration_label_cases') }}
-- depends_on: {{ ref('board_train_delay_daily') }}
-- depends_on: {{ ref('board_suspension_gaps') }}
-- depends_on: {{ ref('board_line_day_metrics') }}
-- depends_on: {{ ref('board_day_worst_segments') }}
-- depends_on: {{ ref('board_day_worst_stations') }}
-- depends_on: {{ ref('board_line_hour_heatmap') }}
-- depends_on: {{ ref('board_station_hour_heatmap') }}
-- depends_on: {{ ref('board_delay_histogram') }}
-- depends_on: {{ ref('board_train_delay_by_line') }}
-- depends_on: {{ ref('board_cr_daily') }}
-- depends_on: {{ ref('board_cr_monthly') }}
-- depends_on: {{ ref('board_survey_lines') }}
-- depends_on: {{ ref('board_freedom_trail') }}
-- Board summary: one row, one JSON column per top-level block of board_data.json. The
-- on-run-end hook (macros/write_build_outputs.sql) adds the `build` block and COPYs this row
-- to out/board_data.json. Runs after every Parquet export so `files` lists what was written.
{%- set out_dir = env_var('MBTA_OUT_DIR', 'out') %}

with

service_window as (
    select
        min(date_day) as first_date,
        max(date_day) as last_date,
        count(*) as n_days
    from {{ ref('dim_dates') }}
),

rider_basis as (
    select
        min(rider_basis_start_date) as first_date,
        max(rider_basis_end_date) as last_date
    from {{ ref('mart_station_reliability') }}
),

row_counts as (
    select json_object(
        'lamp_raw_rows', (select count(*) from {{ ref('stg_lamp__subway_trip_stops') }}),
        'trip_stop_events', (select count(*) from {{ ref('fct_trip_stop_events') }}),
        'trips', (select count(*) from {{ ref('fct_trips') }}),
        'stations', (select count(*) from {{ ref('dim_stations') }}),
        'gated_entry_rows', (select count(*) from {{ ref('stg_mbta__gated_entries') }}),
        'monthly_ridership_rows', (select count(*) from {{ ref('stg_mbta__monthly_ridership') }})
    ) as counts
),

sources as (
    select
        to_json(list(
            json_object('name', name, 'url', url, 'used_for', used_for, 'terms', terms)
            order by sort_order
        )) as sources
    from {{ ref('board_sources') }}
),

holidays as (
    select
        to_json(list(
            json_object(
                'date', strftime(holidays.holiday_date, '%Y-%m-%d'),
                'name', holidays.holiday_name,
                'in_service_window',
                holidays.holiday_date between service_window.first_date and service_window.last_date
            )
            order by holidays.holiday_date
        )) as holidays
    from {{ ref('holidays') }} as holidays
    cross join service_window
),

latest_date as (
    select
        max(service_date) as service_date,
        arg_max(day_type, service_date) as day_type
    from {{ ref('mart_line_day_metrics') }}
    where scope_id = 'system'
),

meta as (
    select
        json_object(
            'title', 'Where the subway falls behind its schedule',
            'question', 'Which lines, stations and times of day run furthest behind schedule or leave'
            || ' the longest gaps between trains, and how many riders does that touch?',
            'sources', sources.sources,
            'pulled_at_utc', (
                select strftime(max(lamp._loaded_at), '%Y-%m-%dT%H:%M:%SZ')
                from {{ ref('stg_lamp__subway_trip_stops') }} as lamp
            ),
            'service_date', strftime(latest_date.service_date, '%Y-%m-%d'),
            'service_date_window', json_object(
                'first', strftime(service_window.first_date, '%Y-%m-%d'),
                'last', strftime(service_window.last_date, '%Y-%m-%d'),
                'days', service_window.n_days
            ),
            'rider_basis_window', json_object(
                'first', strftime(rider_basis.first_date, '%Y-%m-%d'),
                'last', strftime(rider_basis.last_date, '%Y-%m-%d')
            ),
            'row_counts', row_counts.counts,
            'holidays', coalesce(holidays.holidays, json('[]')),
            'thresholds', json_object(
                'late_trip_seconds', {{ var('late_trip_seconds') }},
                'long_gap_ratio', cast({{ var('long_gap_ratio') }} as double),
                'bunched_ratio', cast({{ var('bunched_ratio') }} as double),
                'travel_outlier_seconds', {{ var('travel_outlier_seconds') }},
                'wait_max_headway_seconds', {{ var('wait_max_headway_seconds') }},
                'worse_recent_days', {{ var('worse_recent_days') }},
                'worse_prior_days', {{ var('worse_prior_days') }},
                'worse_min_volume_recent', {{ var('worse_min_volume_recent') }},
                'worse_min_volume_prior', {{ var('worse_min_volume_prior') }},
                'worse_min_delta_seconds', {{ var('worse_min_delta_seconds') }},
                'cause_min_runs_per_day', {{ var('cause_min_runs_per_day') }},
                'cause_min_days', {{ var('cause_min_days') }},
                'cause_dominance_ratio', cast({{ var('cause_dominance_ratio') }} as double),
                'typical_days', {{ var('typical_days') }},
                'usual_min_volume', {{ var('usual_min_volume') }},
                'usual_min_typical_days', {{ var('usual_min_typical_days') }},
                'usual_rule', 'An hour is worse than usual when its value is above the 75th percentile'
                || ' (p75) of the same hour on the earlier {{ var("typical_days") }} days of the same day'
                || ' type, better than usual below the 25th percentile (p25), and about usual from p25 to p75.'
                || ' It is not rated (not_enough_data) with fewer than {{ var("usual_min_volume") }} trips,'
                || ' runs or departures in the hour or fewer than {{ var("usual_min_typical_days") }} earlier days.',
                'histogram_min_minutes', {{ var('histogram_min_minutes') }},
                'histogram_max_minutes', {{ var('histogram_max_minutes') }}
            ),
            'method', 'Recorded run times between stops (arrival to arrival; from departure on a'
            || ' train''s first stop and out of terminals) are compared to the published schedule for'
            || ' every subway train, and actual gaps between trains to scheduled gaps. Rider time lost'
            || ' is an estimate that weights stations by fare-gate entries for the same time of day.',
            'disclaimer', 'Public MBTA data. Live positions from the MBTA V3 API. Not affiliated with the MBTA.',
            'attribution', 'Data provided by MassDOT / MBTA under the MassDOT Developers License Agreement.'
        ) as meta
    from sources
    cross join service_window
    cross join rider_basis
    cross join row_counts
    cross join holidays
    cross join latest_date
),

tiles as (
    select to_json(list(tile order by sort_order)) as tiles
    from {{ ref('board_tiles') }}
),

line_daily as (
    select
        route_id,
        to_json(list(
            json_object(
                'date', strftime(service_date, '%Y-%m-%d'),
                'trips', trips,
                'trips_compared', trips_compared,
                'late_trip_share', {{ board_round('late_trip_share', 4) }},
                'avg_trip_excess_seconds', {{ board_round('avg_trip_excess_seconds', 1) }},
                'long_gap_share', {{ board_round('long_gap_share', 4) }},
                'headway_adherence_share', {{ board_round('headway_adherence_share', 4) }}
            )
            order by service_date
        )) as daily
    from {{ ref('mart_line_daily_reliability') }}
    group by route_id
),

lines as (
    select
        to_json(list(
            json_object(
                'route_id', totals.route_id,
                'line_id', totals.line_id,
                'display_name', totals.display_name,
                'color', totals.route_color_hex,
                'trips', totals.trips,
                'trips_compared', totals.trips_compared,
                'excess_share_of_scheduled', {{ board_round('totals.excess_share_of_scheduled', 4) }},
                'avg_scheduled_trip_minutes', {{ board_round('totals.avg_scheduled_trip_seconds / 60', 1) }},
                'late_trip_share', {{ board_round('totals.late_trip_share', 4) }},
                'avg_trip_excess_seconds', {{ board_round('totals.avg_trip_excess_seconds', 1) }},
                'long_gap_share', {{ board_round('totals.long_gap_share', 4) }},
                'bunched_share', {{ board_round('totals.bunched_share', 4) }},
                'headway_adherence_share', {{ board_round('totals.headway_adherence_share', 4) }},
                'late_trips', totals.late_trips,
                'trips_with_long_runs', totals.trips_with_long_runs,
                'long_run_excess_seconds_sum', totals.long_run_excess_seconds_sum,
                'late_trip_share_excl_long_runs', totals.late_trip_share_excl_long_runs,
                'late_trips_excl_long_runs', totals.late_trips_excl_long_runs,
                'trips_compared_excl_long_runs', totals.trips_compared_excl_long_runs,
                'avg_trip_excess_seconds_excl_long_runs', totals.avg_trip_excess_seconds_excl_long_runs,
                'daily', coalesce(line_daily.daily, json('[]'))
            )
            order by totals.display_order
        )) as lines  -- noqa: RF04
    from {{ ref('board_line_totals') }} as totals
    left join line_daily on totals.route_id = line_daily.route_id
),

worst_station_rows as (
    select *
    from {{ ref('mart_station_overview') }}
    where has_rider_data
    order by weekday_entries_in_long_gaps desc
    limit 8
),

worst_stations as (
    select
        to_json(list(
            json_object(
                'station_id', station_id,
                'station_name', station_name,
                'lines', string_split(line_ids, ','),
                'weekday_gated_entries', cast(round_even(weekday_gated_entries, 0) as bigint),
                'weekday_entries_in_long_gaps', cast(round_even(weekday_entries_in_long_gaps, 0) as bigint),
                'rider_weighted_long_gap_share', {{ board_round('rider_weighted_long_gap_share', 4) }},
                'rider_weighted_excess_seconds', {{ board_round('rider_weighted_excess_seconds', 1) }},
                'explainer', 'On an average weekday, about '
                || format('{:,}', cast(round_even(weekday_entries_in_long_gaps, 0) as bigint))
                || ' of ~' || format('{:,}', cast(round_even(weekday_gated_entries, 0) as bigint))
                || ' gate entries here happen while trains are running a long gap.'
            )
            order by weekday_entries_in_long_gaps desc
        )) as worst_stations
    from worst_station_rows
),

worst_period_rows as (
    select
        periods.route_id,
        routes.display_name,
        periods.service_period_id,
        service_periods.service_period_name,
        service_periods.clock_range,
        periods.trips_compared,
        periods.late_trip_share,
        periods.long_gap_share,
        periods.avg_trip_excess_seconds
    from {{ ref('mart_period_reliability') }} as periods
    inner join {{ ref('dim_routes') }} as routes on periods.route_id = routes.route_id
    inner join {{ ref('dim_service_periods') }} as service_periods
        on periods.service_period_id = service_periods.service_period_id
    where periods.day_type = 'weekday' and periods.trips_compared >= 200
    order by periods.late_trip_share desc
    limit 8
),

worst_periods as (
    select
        to_json(list(
            json_object(
                'route_id', route_id,
                'display_name', display_name,
                'service_period_id', service_period_id,
                'service_period_name', service_period_name,
                'clock_range', clock_range,
                'day_type', 'weekday',
                'trips_compared', trips_compared,
                'late_trip_share', {{ board_round('late_trip_share', 4) }},
                'long_gap_share', {{ board_round('long_gap_share', 4) }},
                'avg_trip_excess_seconds', {{ board_round('avg_trip_excess_seconds', 1) }}
            )
            order by late_trip_share desc
        )) as worst_periods
    from worst_period_rows
),

-- map ---------------------------------------------------------------------------------

map_stations as (
    select
        to_json(list(
            json_object(
                'station_id', station_id,
                'name', station_name,
                'lat', latitude,
                'lon', longitude,
                'route_ids', string_split(route_ids, ','),
                'line_ids', string_split(line_ids, ','),
                'has_rider_data', has_rider_data,
                'avg_daily_gated_entries', cast(round_even(avg_daily_gated_entries, 0) as bigint),
                'excess_seconds', {{ board_round('map_excess_seconds', 1) }},
                'long_gap_share', {{ board_round('map_long_gap_share', 4) }},
                'rider_weighted_excess_seconds', {{ board_round('rider_weighted_excess_seconds', 1) }},
                'rider_weighted_long_gap_share', {{ board_round('rider_weighted_long_gap_share', 4) }},
                'est_daily_entries_in_long_gaps', cast(round_even(est_daily_entries_in_long_gaps, 0) as bigint),
                'weekday_gated_entries', cast(round_even(weekday_gated_entries, 0) as bigint),
                'weekday_entries_in_long_gaps', cast(round_even(weekday_entries_in_long_gaps, 0) as bigint)
            )
            order by station_id
        )) as stations
    from {{ ref('mart_station_overview') }}
),

line_stop_rows as (
    select
        stops.route_id,
        stops.branch_route_id,
        stops.direction_id,
        stops.direction_name,
        stops.direction_destination,
        stops.route_pattern_name,
        stops.stop_order,
        stops.station_id,
        stops.route_color_hex,
        routes.display_name,
        routes.display_order,
        case stops.branch_route_id
            when 'Red-A' then 'Ashmont'
            when 'Red-B' then 'Braintree'
            else routes.branch_name
        end as branch
    from {{ ref('mart_line_stop_sequence') }} as stops
    inner join {{ ref('dim_routes') }} as routes on stops.route_id = routes.route_id
),

line_stop_lists as (
    select
        branch_route_id,
        direction_id,
        min(display_order) as display_order,
        arg_min(route_id, stop_order) as route_id,
        arg_min(display_name, stop_order) as display_name,
        arg_min(branch, stop_order) as branch,
        arg_min(direction_name, stop_order) as direction_name,
        arg_min(direction_destination, stop_order) as direction_destination,
        arg_min(route_pattern_name, stop_order) as route_pattern_name,
        arg_min(route_color_hex, stop_order) as route_color_hex,
        list(station_id order by stop_order) as stops
    from line_stop_rows
    group by branch_route_id, direction_id
),

line_shape_lists as (
    select
        branch_route_id,
        direction_id,
        list([longitude, latitude] order by point_order) as shape
    from {{ ref('mart_line_shapes') }}
    group by branch_route_id, direction_id
),

map_lines as (
    select
        to_json(list(
            json_object(
                'route_id', stop_lists.route_id,
                'branch_route_id', stop_lists.branch_route_id,
                'display_name', stop_lists.display_name,
                'branch', stop_lists.branch,
                'direction_id', stop_lists.direction_id,
                'direction', stop_lists.direction_name,
                'destination', stop_lists.direction_destination,
                'pattern', stop_lists.route_pattern_name,
                'color', stop_lists.route_color_hex,
                'stops', stop_lists.stops,
                'shape', shape_lists.shape
            )
            order by stop_lists.display_order, stop_lists.branch_route_id, stop_lists.direction_id
        )) as lines  -- noqa: RF04
    from line_stop_lists as stop_lists
    left join line_shape_lists as shape_lists
        on
            stop_lists.branch_route_id = shape_lists.branch_route_id
            and stop_lists.direction_id = shape_lists.direction_id
),

map_periods as (
    select
        to_json(list(
            json_object(
                'service_period_id', service_period_id,
                'name', service_period_name,
                'clock_range', clock_range,
                'start_minute', start_minute,
                'end_minute', end_minute,
                'sort_order', sort_order,
                'weekday_late_trip_share', {{ board_round('late_trip_share', 4) }},
                'weekday_long_gap_share', {{ board_round('long_gap_share', 4) }},
                'weekday_trips_compared', trips_compared
            )
            order by sort_order
        )) as periods
    from (
        select
            service_periods.service_period_id,
            service_periods.service_period_name,
            service_periods.clock_range,
            service_periods.start_minute,
            service_periods.end_minute,
            service_periods.sort_order,
            sum(periods.late_trip_share * periods.trips_compared)
            / nullif(sum(periods.trips_compared), 0) as late_trip_share,
            sum(periods.long_gap_share * periods.headway_observations)
            / nullif(sum(periods.headway_observations), 0) as long_gap_share,
            cast(sum(periods.trips_compared) as bigint) as trips_compared
        from {{ ref('dim_service_periods') }} as service_periods
        left join {{ ref('mart_period_reliability') }} as periods
            on
                service_periods.service_period_id = periods.service_period_id
                and periods.day_type = 'weekday'
        group by all
    ) as period_totals
),

expected_branches as (
    select ['Red-A', 'Red-B', 'Mattapan', 'Orange', 'Green-B', 'Green-C', 'Green-D', 'Green-E', 'Blue'] as branches
),

present_branches as (
    select list(distinct branch_route_id order by branch_route_id) as branches
    from line_stop_lists
),

map_coverage as (
    select
        json_object(
            'stations', count(*),
            'with_coordinates', count(*) filter (
                where overview.latitude is not null and overview.longitude is not null
            ),
            'with_rider_data', count(*) filter (where overview.has_rider_data),
            'with_lamp_events', count(*) filter (where overview.trip_stop_events > 0),
            'branches_expected', any_value(expected_branches.branches),
            'branches_present', any_value(present_branches.branches),
            'branches_missing', list_sort(
                list_filter(
                    any_value(expected_branches.branches),
                    b -> not list_contains(any_value(present_branches.branches), b)
                )
            )
        ) as coverage
    from {{ ref('mart_station_overview') }} as overview
    cross join expected_branches
    cross join present_branches
),

map_block as (
    select
        json_object(
            'crs', 'WGS84 (EPSG:4326). Stations from GTFS stops.txt, track shapes from GTFS shapes.txt as [lon, lat].',
            'gtfs_as_of', (
                select strftime(max(stop_sequence.gtfs_as_of_date), '%Y-%m-%d')
                from {{ ref('mart_line_stop_sequence') }} as stop_sequence
            ),
            'shading_note', 'map_* values are rider-weighted where the station has fare gates, otherwise'
            || ' weighted by train arrivals (has_rider_data = false).',
            'stations', map_stations.stations,
            'lines', map_lines.lines,
            'periods', map_periods.periods,
            'coverage', map_coverage.coverage
        ) as map  -- noqa: RF04
    from map_stations
    cross join map_lines
    cross join map_periods
    cross join map_coverage
),

-- files written to the out directory by the export models ------------------------------

file_blobs as (
    select
        parse_filename(filename) as file_name,
        size
    from read_blob('{{ out_dir }}/*.parquet')
),

file_meta as (
    select
        parse_filename(file_name) as file_name,
        num_rows
    from parquet_file_metadata('{{ out_dir }}/*.parquet')
),

files as (
    select
        to_json(list(
            json_object('file', blobs.file_name, 'bytes', blobs.size, 'rows', parquet_meta.num_rows)
            order by blobs.file_name
        )) as files
    from file_blobs as blobs
    inner join file_meta as parquet_meta on blobs.file_name = parquet_meta.file_name
),

-- data coverage (mart_data_coverage, mart_station_overview) ----------------------------

coverage_routes as (
    select
        coverage_rows.*,
        routes.display_name,
        routes.display_order
    from {{ ref('mart_data_coverage') }} as coverage_rows
    inner join {{ ref('dim_routes') }} as routes on coverage_rows.route_id = routes.route_id
),

coverage_system as (
    select
        json_object(
            'trip_stop_events', sum(trip_stop_events),
            'without_scheduled_travel', sum(events_without_scheduled_travel),
            'without_scheduled_headway', sum(events_without_scheduled_headway),
            'without_any_schedule', sum(events_without_any_schedule),
            'share_without_scheduled_travel',
            {{ board_round('sum(events_without_scheduled_travel) / sum(trip_stop_events)', 4) }},
            'share_without_scheduled_headway',
            {{ board_round('sum(events_without_scheduled_headway) / sum(trip_stop_events)', 4) }},
            'share_without_any_schedule',
            {{ board_round('sum(events_without_any_schedule) / sum(trip_stop_events)', 4) }},
            'events_at_ungated_stations', sum(events_at_ungated_stations),
            'share_events_at_ungated_stations',
            {{ board_round('sum(events_at_ungated_stations) / sum(trip_stop_events)', 4) }}
        ) as system_totals
    from (
        select
            cast(trip_stop_events as bigint) as trip_stop_events,
            cast(events_without_scheduled_travel as bigint) as events_without_scheduled_travel,
            cast(events_without_scheduled_headway as bigint) as events_without_scheduled_headway,
            cast(events_without_any_schedule as bigint) as events_without_any_schedule,
            cast(events_at_ungated_stations as bigint) as events_at_ungated_stations
        from coverage_routes
    ) as counts
),

coverage_by_route as (
    select
        to_json(list(
            json_object(
                'route_id', route_id,
                'display_name', display_name,
                'trip_stop_events', trip_stop_events,
                'without_scheduled_travel', events_without_scheduled_travel,
                'share_without_scheduled_travel', {{ board_round('share_without_scheduled_travel', 4) }},
                'without_scheduled_headway', events_without_scheduled_headway,
                'share_without_scheduled_headway', {{ board_round('share_without_scheduled_headway', 4) }},
                'without_any_schedule', events_without_any_schedule,
                'share_without_any_schedule', {{ board_round('share_without_any_schedule', 4) }},
                'stations_served', stations_served,
                'stations_without_gated_entries', stations_without_gated_entries,
                'share_events_at_ungated_stations', {{ board_round('share_events_at_ungated_stations', 4) }}
            )
            order by display_order
        )) as by_route
    from coverage_routes
),

ungated as (
    select
        station_id,
        line_ids
    from {{ ref('mart_station_overview') }}
    where not has_gated_entries
),

ungated_by_line as (
    select to_json(map_from_entries(list((line_id, station_ids) order by line_id))) as by_line
    from (
        select
            line_id,
            list(station_id order by line_ids, station_id) as station_ids
        from (
            select
                station_id,
                line_ids,
                unnest(string_split(line_ids, ',')) as line_id
            from ungated
        ) as ungated_lines
        group by line_id
    ) as per_line
),

ungated_block as (
    select
        json_object(
            'count', (select count(*) from ungated),
            'of_stations', (select count(*) from {{ ref('mart_station_overview') }}),
            'station_ids', (select list(u.station_id order by u.line_ids, u.station_id) from ungated as u),
            'by_line', ungated_by_line.by_line
        ) as stations_without_gated_entries
    from ungated_by_line
),

green_stations as (
    select
        count(*) as stations,
        count(*) filter (where not has_gated_entries) as ungated_stations
    from {{ ref('mart_station_overview') }}
    where list_contains(string_split(line_ids, ','), 'Green')
),

green_events as (
    select sum(events_at_ungated_stations) / sum(trip_stop_events) as share_of_trip_stop_events
    from coverage_routes
    where line_id = 'Green'
),

data_coverage as (
    select
        json_object(
            'definitions', json_object(
                'no_scheduled_travel', 'LAMP has no scheduled run time from the previous stop, or it is'
                || ' zero or less (includes the first stop of every trip and added trips).',
                'no_scheduled_headway', 'LAMP has no scheduled gap since the previous train, or it is zero.',
                'ungated_station', 'Station not in MBTA gated-entry data, so it has no rider weight.'
            ),
            'system', coverage_system.system_totals,
            'by_route', coverage_by_route.by_route,
            'stations_without_gated_entries', ungated_block.stations_without_gated_entries,
            'green_line_surface', json_object(
                'stations', green_stations.stations,
                'ungated_stations', green_stations.ungated_stations,
                'share_of_stations', {{ board_round('green_stations.ungated_stations / green_stations.stations', 4) }},
                'share_of_trip_stop_events', {{ board_round('green_events.share_of_trip_stop_events', 4) }},
                'note', 'Approximated as Green Line stations without gated-entry data. All are surface'
                || ' stops except Symphony (underground, no gate data) and Longwood (gated rows lack a stop id).'
            )
        ) as coverage
    from coverage_system
    cross join coverage_by_route
    cross join ungated_block
    cross join green_stations
    cross join green_events
),

-- decision metrics (train delay, rider time lost, segments, buffer, getting worse, schedule or service)

train_delay_headline as (
    select tile from {{ ref('board_tiles') }}
    where tile_id = 'train_delay_weekday'
),

train_delay_bases as (
    select
        to_json(map_from_entries(list((
            day_basis,
            json_object(
                'service_dates', service_dates,
                'runs_observed', runs_observed,
                'runs_compared', runs_compared,
                'trips_compared', trips_compared,
                'positive_excess_seconds_total', positive_excess_seconds,
                'net_excess_seconds_total', net_excess_seconds,
                'avg_daily_positive_seconds', avg_daily_positive_excess_seconds,
                'avg_daily_positive_label', {{ format_duration('avg_daily_positive_excess_seconds') }},
                'avg_daily_net_seconds', avg_daily_net_excess_seconds,
                'avg_daily_net_label', {{ format_duration('avg_daily_net_excess_seconds') }},
                'avg_daily_runs', avg_daily_runs,
                'positive_per_run_seconds', positive_excess_seconds_per_run,
                'positive_per_run_label', {{ format_duration('positive_excess_seconds_per_run') }},
                'net_per_run_seconds', net_excess_seconds_per_run,
                'net_per_run_label', {{ format_duration('net_excess_seconds_per_run') }},
                'positive_per_trip_seconds', positive_excess_seconds_per_trip,
                'positive_per_trip_label', {{ format_duration('positive_excess_seconds_per_trip') }},
                'net_per_trip_seconds', net_excess_seconds_per_trip,
                'net_per_trip_label', {{ format_duration('net_excess_seconds_per_trip') }},
                'long_runs', long_runs,
                'long_run_positive_seconds_total', long_run_positive_excess_seconds,
                'long_run_net_seconds_total', long_run_net_excess_seconds,
                'avg_daily_positive_excl_long_runs_seconds', avg_daily_positive_excess_seconds_excl_long_runs,
                'avg_daily_net_excl_long_runs_seconds', avg_daily_net_excess_seconds_excl_long_runs,
                'runs_actual_missing', runs_actual_missing,
                'runs_scheduled_missing', runs_scheduled_missing,
                'runs_actual_not_positive', runs_actual_not_positive,
                'actual_not_positive_net_seconds', actual_not_positive_net_seconds,
                'runs_scheduled_not_positive', runs_scheduled_not_positive,
                'scheduled_not_positive_net_seconds', scheduled_not_positive_net_seconds
            )
        ) order by day_basis))) as bases
    from {{ ref('mart_train_delay_summary') }}
),

suspension_gap_kind_list as (
    select kinds.gap_kind
    from (
        values
        ('departure_not_recorded'), ('departure_recorded_inside'), ('no_departure_recorded_inside'),
        ('spans_service_day_boundary')
    ) as kinds (gap_kind)
),

suspension_gap_kind_counts as (
    select
        gap_kind,
        count(*) as n,
        sum(gap_seconds) as gap_seconds
    from {{ ref('fct_suspension_gaps') }}
    group by gap_kind
),

suspension_gap_kinds as (
    select
        to_json(map_from_entries(list((
            kinds.gap_kind,
            json_object('count', coalesce(counted.n, 0), 'seconds', coalesce(counted.gap_seconds, 0))
        ) order by kinds.gap_kind))) as by_kind
    from suspension_gap_kind_list as kinds
    left join suspension_gap_kind_counts as counted on kinds.gap_kind = counted.gap_kind
),

suspension_gap_totals as (
    select
        json_object(
            'threshold_seconds', {{ var('wait_max_headway_seconds') }},
            'count', count(*),
            'seconds', coalesce(sum(gaps.gap_seconds), 0),
            'label', {{ format_duration('coalesce(sum(gaps.gap_seconds), 0)') }},
            'waited_count', count(*) filter (where gaps.is_passenger_wait),
            'waited_seconds', coalesce(sum(gaps.gap_seconds) filter (where gaps.is_passenger_wait), 0),
            'non_wait_count', count(*) filter (where not gaps.is_passenger_wait),
            'non_wait_seconds', coalesce(sum(gaps.gap_seconds) filter (where not gaps.is_passenger_wait), 0),
            'by_kind', any_value(suspension_gap_kinds.by_kind),
            'rule', 'Gaps over 1 hour between trains at a platform are kept in their own columns. Each is'
            || ' checked against the recorded departures: a gap that starts on an earlier service date'
            || ' runs through the overnight break and is not a wait; where trains were recorded leaving'
            || ' the platform inside the gap, the wait is split at those departures.'
        ) as gaps
    from {{ ref('fct_suspension_gaps') }} as gaps
    cross join suspension_gap_kinds
),

rider_headline as (
    select tile from {{ ref('board_tiles') }}
    where tile_id = 'rider_time_lost'
),

rider_weekly as (
    select
        to_json(list(
            json_object(
                'week_start', strftime(week_start_date, '%Y-%m-%d'),
                'week_end', strftime(week_end_date, '%Y-%m-%d'),
                'service_dates', service_dates,
                'is_complete_week', is_complete_week,
                'avg_daily_seconds', avg_daily_rider_time_lost_seconds,
                'avg_daily_label', avg_daily_rider_time_lost_label,
                'avg_weekday_seconds', avg_weekday_rider_time_lost_seconds,
                'avg_weekday_label', avg_weekday_rider_time_lost_label,
                'per_entry_seconds', time_lost_per_entry_seconds,
                'per_entry_label', time_lost_per_entry_label
            )
            order by week_start_date
        )) as weeks
    from {{ ref('board_rider_time_lost_weekly') }}
),

top_segment_rows as (
    select * from {{ ref('board_segments') }}
    where is_top_10
),

top_segments as (
    select
        to_json(list(
            json_object(
                'rank', loss_rank,
                'segment_id', segment_id,
                'segment_name', segment_name,
                'line_id', line_id,
                'direction_id', direction_id,
                'from_station_id', from_station_id,
                'to_station_id', to_station_id,
                'train_delay_weekday_seconds', train_delay_weekday_seconds,
                'train_delay_weekday_label', train_delay_weekday_label,
                'train_delay_weekday_net_seconds', train_delay_weekday_net_seconds,
                'train_delay_weekday_net_label', train_delay_weekday_net_label,
                'avg_weekday_runs', avg_weekday_runs,
                'positive_excess_per_run_seconds', positive_excess_per_run_seconds,
                'positive_excess_per_run_label', positive_excess_per_run_label,
                'net_excess_per_run_seconds', net_excess_per_run_seconds,
                'net_excess_per_run_label', net_excess_per_run_label,
                'share_of_segment_train_delay', share_of_segment_train_delay,
                'long_runs', long_runs,
                'long_run_train_delay_weekday_seconds', long_run_train_delay_weekday_seconds,
                'is_terminal_departure', is_terminal_departure,
                'is_terminal_arrival', is_terminal_arrival,
                'terminal_time_split', terminal_time_split,
                'terminal_hold_weekday_seconds', terminal_hold_weekday_seconds,
                'terminal_hold_weekday_label', terminal_hold_weekday_label,
                'terminal_hold_per_run_seconds', terminal_hold_per_run_seconds,
                'terminal_hold_per_run_label', terminal_hold_per_run_label,
                'terminal_hold_negative_runs', terminal_hold_negative_runs,
                'terminal_hold_weekday_negative_seconds', terminal_hold_weekday_negative_seconds,
                'terminal_hold_median_seconds', terminal_hold_median_seconds,
                'terminal_hold_median_label', terminal_hold_median_label,
                'terminal_hold_p90_seconds', terminal_hold_p90_seconds,
                'terminal_hold_p90_label', terminal_hold_p90_label,
                'terminal_hold_mean_seconds', terminal_hold_mean_seconds,
                'terminal_hold_mean_label', terminal_hold_mean_label,
                'worst_window_days', worst_window_days,
                'worst_window_start_date', worst_window_start_date,
                'worst_window_end_date', worst_window_end_date,
                'worst_window_share_of_delay', worst_window_share_of_delay,
                'worst_window_share_of_runs', worst_window_share_of_runs,
                'start_station_avg_weekday_entries', start_station_avg_weekday_entries,
                'buffer_seconds', buffer_seconds,
                'buffer_label', buffer_label,
                'buffer_index', buffer_index,
                'cause_class', cause_class
            )
            order by loss_rank
        )) as segments,
        sum(train_delay_weekday_seconds) as top_10_seconds
    from top_segment_rows
),

segment_totals as (
    select
        sum(train_delay_weekday_seconds) as segment_train_delay_seconds,
        count(*) as segments,
        count(*) filter (where start_station_has_gate_data) as segments_with_start_station_gate_data,
        count(*) filter (where is_terminal_departure) as terminal_departure_segments,
        count(*) filter (where is_terminal_arrival) as terminal_arrival_segments,
        count(*) filter (where is_terminal_departure or is_terminal_arrival) as terminal_segments
    from {{ ref('board_segments') }}
),

cause_counts as (
    select to_json(map_from_entries(list((cause_class, n) order by cause_class))) as counts
    from (
        select
            cause_class,
            count(*) as n
        from {{ ref('board_segments') }}
        group by cause_class
    ) as per_class
),

worse_segments as (
    select
        to_json(list(
            json_object(
                'segment_id', segment_id,
                'segment_name', segment_name,
                'line_id', line_id,
                'direction_id', direction_id,
                'runs_recent', runs_recent,
                'runs_prior', runs_prior,
                'avg_excess_seconds_recent', avg_excess_seconds_recent,
                'avg_excess_seconds_prior', avg_excess_seconds_prior,
                'delta_excess_seconds', delta_excess_seconds,
                'delta_excess_label', delta_excess_label,
                'avg_positive_excess_seconds_recent', avg_positive_excess_seconds_recent,
                'avg_positive_excess_seconds_prior', avg_positive_excess_seconds_prior,
                'delta_positive_excess_seconds', delta_positive_excess_seconds,
                'delta_above_typical_seconds', delta_above_typical_seconds,
                'delay_share_change', delay_share_change
            )
            order by delta_excess_seconds desc, segment_id asc
        )) as segments
    from {{ ref('board_segments') }}
    where is_getting_worse
),

worse_stations as (
    select
        to_json(list(
            json_object(
                'station_id', station_id,
                'station_name', station_name,
                'line_id', line_id,
                'departures_recent', departures_recent,
                'departures_prior', departures_prior,
                'excess_per_rider_recent_seconds', excess_per_rider_recent_seconds,
                'excess_per_rider_prior_seconds', excess_per_rider_prior_seconds,
                'delta_excess_seconds', delta_excess_seconds,
                'delta_excess_label', delta_excess_label,
                'delta_excess_wait_seconds', delta_excess_wait_seconds,
                'delta_excess_ride_seconds', delta_excess_ride_seconds,
                'delta_above_typical_seconds', delta_above_typical_seconds,
                'delta_excess_with_gaps_seconds', delta_excess_with_gaps_seconds,
                'loss_share_change', loss_share_change
            )
            order by delta_excess_seconds desc, station_id asc, line_id asc
        )) as stations
    from {{ ref('board_station_trend') }}
    where is_getting_worse
),

trend_window as (
    select
        any_value(prior_start_date) as prior_start_date,
        any_value(prior_end_date) as prior_end_date,
        any_value(recent_start_date) as recent_start_date,
        any_value(recent_end_date) as recent_end_date,
        any_value(typical_delta_excess_seconds) as station_typical_delta_seconds
    from {{ ref('board_station_trend') }}
),

segment_typical as (
    select any_value(typical_delta_excess_seconds) as typical_delta_excess_seconds
    from {{ ref('mart_segment_trend') }}
),

line_order as (
    select
        line_id,
        min(display_order) as display_order
    from {{ ref('dim_routes') }}
    group by line_id
),

line_buffers as (
    select
        to_json(list(
            json_object(
                'line_id', line_buffer.line_id,
                'avg_segment_buffer_seconds', line_buffer.avg_segment_buffer_seconds,
                'avg_segment_buffer_label', line_buffer.avg_segment_buffer_label,
                'buffer_index', line_buffer.buffer_index,
                'max_segment_buffer_seconds', line_buffer.max_segment_buffer_seconds,
                'max_segment_buffer_label', line_buffer.max_segment_buffer_label,
                'max_buffer_segment_name', line_buffer.max_buffer_segment_name
            )
            order by line_order.display_order
        )) as line_buffer_list
    from {{ ref('board_line_buffer') }} as line_buffer
    inner join line_order on line_buffer.line_id = line_order.line_id
),

decision as (
    select
        json_object(
            'train_delay', json_object(
                'headline', train_delay_headline.tile,
                'is_estimate', false,
                'by_day_basis', train_delay_bases.bases,
                'rule', 'Every recorded run between two stops: actual arrival-to-arrival time minus'
                || ' scheduled time. Positive counts late time only (max(actual - scheduled, 0)); net lets'
                || ' faster runs offset slower ones. Runs over 30 minutes are included and also shown on'
                || ' their own. Runs without both times positive are counted by reason, not summed.'
            ),
            'rider_time_lost', json_object(
                'headline', rider_headline.tile,
                'is_estimate', true,
                'estimate_note', 'Estimate based on people entering stations through fare gates,'
                || ' assuming riders arrive at random times (expected wait = sum(h^2) / (2 sum(h))).',
                'clamped_at_zero', false,
                'clamp_note', 'Not clamped: cells where trains ran closer together or faster than'
                || ' scheduled offset cells where they ran slower, so this is net time lost.',
                'suspension_gaps', suspension_gap_totals.gaps,
                'weekly', coalesce(rider_weekly.weeks, json('[]'))
            ),
            'segments', json_object(
                'segments', segment_totals.segments,
                'segments_with_start_station_gate_data', segment_totals.segments_with_start_station_gate_data,
                'terminal_segments', segment_totals.terminal_segments,
                'terminal_departure_segments', segment_totals.terminal_departure_segments,
                'terminal_arrival_segments', segment_totals.terminal_arrival_segments,
                'top_10', coalesce(top_segments.segments, json('[]')),
                'top_10_share_of_segment_train_delay',
                top_segments.top_10_seconds / nullif(segment_totals.segment_train_delay_seconds, 0),
                'rank_rule', 'Segments ranked by measured train delay: positive excess seconds summed over'
                || ' weekday train runs, per average weekday. Riders are not used in the rank.',
                'top_10_share_rule', 'Weekday train delay of the 10 top segments divided by the sum over'
                || ' all segments.'
            ),
            'line_buffer', coalesce(line_buffers.line_buffer_list, json('[]')),
            'cause_counts', cause_counts.counts,
            'getting_worse', json_object(
                'prior_window', json_object(
                    'first', strftime(trend_window.prior_start_date, '%Y-%m-%d'),
                    'last', strftime(trend_window.prior_end_date, '%Y-%m-%d')
                ),
                'recent_window', json_object(
                    'first', strftime(trend_window.recent_start_date, '%Y-%m-%d'),
                    'last', strftime(trend_window.recent_end_date, '%Y-%m-%d')
                ),
                'segment_typical_delta_seconds', segment_typical.typical_delta_excess_seconds,
                'station_typical_delta_seconds', trend_window.station_typical_delta_seconds,
                'rule', 'Flagged when there were at least {{ var("worse_min_volume_recent") }} train runs'
                || ' (segments) or departures (stations) in the recent window and'
                || ' {{ var("worse_min_volume_prior") }} in the prior window, and excess time rose by at'
                || ' least {{ var("worse_min_delta_seconds") }} s and by at least'
                || ' {{ var("worse_min_delta_seconds") }} s more than the typical (median) change.',
                'segments', coalesce(worse_segments.segments, json('[]')),
                'stations', coalesce(worse_stations.stations, json('[]'))
            )
        ) as decision
    from rider_headline
    cross join train_delay_headline
    cross join train_delay_bases
    cross join suspension_gap_totals
    cross join rider_weekly
    cross join top_segments
    cross join segment_totals
    cross join cause_counts
    cross join worse_segments
    cross join worse_stations
    cross join trend_window
    cross join segment_typical
    cross join line_buffers
),

latest_measures as (
    select
        metrics.scope_id,
        any_value(metrics.scope_name) as scope_name,
        any_value(metrics.route_color_hex) as route_color_hex,
        to_json(map_from_entries(list((
            metrics.measure,
            json_object(
                'unit', metrics.unit,
                'value', metrics.value,
                'value_label', metrics.value_label,
                'numerator', metrics.numerator,
                'denominator', metrics.denominator,
                'typical_days', metrics.typical_days,
                'typical_first_date', strftime(metrics.typical_first_date, '%Y-%m-%d'),
                'typical_last_date', strftime(metrics.typical_last_date, '%Y-%m-%d'),
                'typical_median', metrics.typical_median,
                'typical_median_label', metrics.typical_median_label,
                'typical_mean', metrics.typical_mean,
                'diff_vs_median', metrics.diff_vs_median,
                'diff_vs_median_label', metrics.diff_vs_median_label,
                'diff_vs_mean', metrics.diff_vs_mean
            )
        ) order by metrics.measure))) as measures,
        max(metrics.value) filter (where metrics.measure = 'late_trip_share') as late_share,
        max(metrics.numerator) filter (where metrics.measure = 'late_trip_share') as late_trips,
        max(metrics.denominator) filter (where metrics.measure = 'late_trip_share') as trips_compared,
        max(metrics.typical_median) filter (where metrics.measure = 'late_trip_share') as typical_late_share,
        max(metrics.typical_days) filter (where metrics.measure = 'late_trip_share') as typical_days
    from {{ ref('board_line_day_metrics') }} as metrics
    inner join latest_date on metrics.service_date = latest_date.service_date
    group by metrics.scope_id
),

latest_segments as (
    select
        worst.scope_id,
        to_json(list(json_object(
            'rank', worst.day_rank,
            'segment_id', worst.segment_id,
            'segment_name', worst.segment_name,
            'line_id', worst.line_id,
            'direction_id', worst.direction_id,
            'runs_compared', worst.runs_compared,
            'train_delay_seconds', worst.positive_excess_seconds,
            'train_delay_label', worst.positive_excess_label,
            'train_delay_net_seconds', worst.net_excess_seconds,
            'per_run_seconds', worst.positive_excess_per_run_seconds,
            'typical_days', worst.typical_days,
            'typical_median_seconds', worst.typical_median_positive_seconds,
            'typical_median_label', worst.typical_median_positive_label,
            'typical_mean_seconds', worst.typical_mean_positive_seconds,
            'diff_vs_median_seconds', worst.diff_vs_median_seconds,
            'diff_vs_median_label', worst.diff_vs_median_label,
            'diff_vs_mean_seconds', worst.diff_vs_mean_seconds
        ) order by worst.day_rank)) as segments
    from {{ ref('board_day_worst_segments') }} as worst
    inner join latest_date on worst.service_date = latest_date.service_date
    group by worst.scope_id
),

latest_stations as (
    select
        worst.scope_id,
        to_json(list(json_object(
            'rank', worst.day_rank,
            'station_id', worst.station_id,
            'station_name', worst.station_name,
            'long_gaps', worst.long_gaps,
            'headway_observations', worst.headway_observations,
            'long_gap_share', worst.long_gap_share,
            'typical_days', worst.typical_days,
            'typical_median_long_gaps', worst.typical_median_long_gaps,
            'typical_mean_long_gaps', worst.typical_mean_long_gaps,
            'diff_vs_median_long_gaps', worst.diff_vs_median_long_gaps,
            'diff_vs_mean_long_gaps', worst.diff_vs_mean_long_gaps,
            'typical_median_long_gap_share', worst.typical_median_long_gap_share,
            'diff_vs_median_long_gap_share', worst.diff_vs_median_long_gap_share
        ) order by worst.day_rank)) as stations
    from {{ ref('board_day_worst_stations') }} as worst
    inner join latest_date on worst.service_date = latest_date.service_date
    group by worst.scope_id
),

latest_day as (
    select
        json_object(
            'service_date', strftime(latest_date.service_date, '%Y-%m-%d'),
            'day_type', latest_date.day_type,
            'typical_rule', 'Typical = median (and mean) of the same measure on the most recent'
            || ' {{ var("typical_days") }} earlier service dates of the same day type with data for'
            || ' that line; diff = the day''s value minus the typical value.',
            'worst_segments_rule', 'The 3 segments with the most train delay that day (positive seconds'
            || ' over scheduled, summed over the day''s runs; ties by segment_id).',
            'worst_stations_rule', 'The 3 stations with the most long gaps between trains that day'
            || ' (ties by long gap share, then station_id).',
            'scopes', to_json(list(json_object(
                'scope_id', measures.scope_id,
                'scope_name', measures.scope_name,
                'route_color_hex', measures.route_color_hex,
                'comparison', format(
                    '{:.1f}% of trips ran {} or more minutes late ({:,} of {:,});'
                    || ' a typical {} over the last {} {}s: {:.1f}%.',
                    100 * measures.late_share,
                    {{ var('late_trip_seconds') }} // 60,
                    cast(measures.late_trips as bigint),
                    cast(measures.trips_compared as bigint),
                    latest_date.day_type,
                    measures.typical_days,
                    latest_date.day_type,
                    100 * measures.typical_late_share
                ),
                'measures', measures.measures,
                'worst_segments', coalesce(segments.segments, json('[]')),
                'worst_stations', coalesce(stations.stations, json('[]'))
            ) order by measures.scope_id != 'system', routes.display_order))
        ) as latest_day
    from latest_measures as measures
    cross join latest_date
    left join {{ ref('dim_routes') }} as routes on measures.scope_id = routes.route_id
    left join latest_segments as segments on measures.scope_id = segments.scope_id
    left join latest_stations as stations on measures.scope_id = stations.scope_id
    group by latest_date.service_date, latest_date.day_type
),

cr_latest_month as (
    select max(month_start_date) as month_start_date
    from {{ ref('mart_cr_monthly') }}
    where scope_id = 'commuter_rail' and is_complete_reliability_month
),

cr_boardings_month as (
    select max(month_start_date) as month_start_date
    from {{ ref('mart_cr_monthly') }}
    where scope_id = 'commuter_rail' and is_complete_boardings_month
),

cr_month_rows as (
    select
        to_json(list(json_object(
            'scope_id', monthly.scope_id,
            'display_name', coalesce(routes.display_name, 'All Commuter Rail'),
            'reliability_days', monthly.reliability_days,
            'on_time_trips', monthly.on_time_trips,
            'counted_trips', monthly.counted_trips,
            'on_time_share', monthly.on_time_share,
            'peak_on_time_share', monthly.peak_on_time_share,
            'off_peak_on_time_share', monthly.off_peak_on_time_share,
            'cancelled_trips', monthly.cancelled_trips,
            'cancelled_share', monthly.cancelled_share
        ) order by monthly.scope_id != 'commuter_rail', routes.display_order)) as month_rows
    from {{ ref('mart_cr_monthly') }} as monthly
    inner join cr_latest_month on monthly.month_start_date = cr_latest_month.month_start_date
    left join {{ ref('dim_cr_routes') }} as routes on monthly.scope_id = routes.route_id
    where monthly.scope_id = 'commuter_rail' or routes.route_id is not null
),

cr_boardings_rows as (
    select
        to_json(list(json_object(
            'scope_id', monthly.scope_id,
            'boardings_days', monthly.boardings_days,
            'estimated_boardings_sum', monthly.estimated_boardings_sum,
            'avg_daily_estimated_boardings', monthly.avg_daily_estimated_boardings
        ) order by monthly.scope_id)) as month_rows
    from {{ ref('mart_cr_monthly') }} as monthly
    inner join cr_boardings_month on monthly.month_start_date = cr_boardings_month.month_start_date
    where monthly.scope_id = 'commuter_rail'
        or monthly.scope_id in (select r.route_id from {{ ref('dim_cr_routes') }} as r)
),

commuter_rail as (
    select
        json_object(
            'routes', (select count(*) from {{ ref('dim_cr_routes') }}),
            'reliability_date_range', json_object(
                'first', (
                    select strftime(min(src.service_date), '%Y-%m-%d') from {{ ref('stg_mbta__cr_reliability') }} as src
                ),
                'last', (
                    select strftime(max(src.service_date), '%Y-%m-%d') from {{ ref('stg_mbta__cr_reliability') }} as src
                )
            ),
            'boardings_date_range', json_object(
                'first', (
                    select strftime(min(src.service_date), '%Y-%m-%d') from {{ ref('stg_mbta__cr_boardings') }} as src
                ),
                'last', (
                    select strftime(max(src.service_date), '%Y-%m-%d') from {{ ref('stg_mbta__cr_boardings') }} as src
                )
            ),
            'latest_full_month', strftime(cr_latest_month.month_start_date, '%Y-%m'),
            'latest_full_month_rows', cr_month_rows.month_rows,
            'latest_full_boardings_month', strftime(cr_boardings_month.month_start_date, '%Y-%m'),
            'latest_full_boardings_month_rows', cr_boardings_rows.month_rows,
            'on_time_rule', 'On-time share = trips the MBTA counts as on time / trips counted'
            || ' (otp_numerator / otp_denominator), summed over routes and days before dividing.'
            || ' Cancelled share = cancelled trips / the same trips counted (the file gives one denominator).',
            'boardings_note', 'estimated_boardings is the MBTA''s own estimate from scaled conductor counts.'
            || ' Franklin and Foxboro trains are reported together on CR-Franklin.',
            'scope_note', 'Totals are the 13 current CR- routes. CR-Middleborough (ended 2025-03-23) and the'
            || ' seasonal CapeFlyer are kept as their own rows in cr_daily.parquet and out of the totals.'
            || ' Commuter Rail is not part of train delay or the segment ranking.'
        ) as commuter_rail
    from cr_latest_month
    cross join cr_boardings_month
    cross join cr_month_rows
    cross join cr_boardings_rows
),

survey as (
    select json_object(
        'label', '2025 survey',
        'scopes', (select to_json(list(distinct scope_id order by scope_id)) from {{ ref('mart_survey_lines') }}),
        'measures', (
            select to_json(list(distinct measure_group || ': ' || measure order by measure_group || ': ' || measure))
            from {{ ref('mart_survey_lines') }}
        ),
        'rows', (select count(*) from {{ ref('mart_survey_lines') }}),
        'note', 'MBTA 2025 System-Wide Passenger Survey: weighted share of riders per category, with'
        || ' respondents (n) and margin of error. Green Line is one line in the survey (no branch totals).'
    ) as survey
),

charts as (
    select json_object(
        'heatmap_files', ['line_hour_heatmap.parquet', 'station_hour_heatmap.parquet'],
        'histogram_file', 'delay_histogram.parquet',
        'share_by_line_file', 'train_delay_by_line.parquet',
        'date_filter_file', 'line_day_metrics.parquet',
        'share_by_line_weekday', (
            select
                to_json(list(json_object(
                    'route_id', route_id,
                    'display_name', display_name,
                    'route_color_hex', route_color_hex,
                    'positive_excess_seconds', positive_excess_seconds,
                    'avg_daily_positive_excess_seconds', avg_daily_positive_excess_seconds,
                    'share_of_positive_excess', share_of_positive_excess
                ) order by share_of_positive_excess desc))
            from {{ ref('board_train_delay_by_line') }}
            where period_kind = 'weekday'
        )
    ) as charts
),

glossary as (
    select to_json(list(json_object('term', term, 'meaning', meaning) order by sort_order)) as glossary
    from {{ ref('board_glossary') }}
)

select
    meta.meta,
    coalesce(tiles.tiles, json('[]')) as tiles,
    coalesce(lines.lines, json('[]')) as lines,  -- noqa: RF04
    coalesce(worst_stations.worst_stations, json('[]')) as worst_stations,
    coalesce(worst_periods.worst_periods, json('[]')) as worst_periods,
    'Weekday line x service period cells with at least 200 compared trips, ranked by share of'
    || ' trips 5+ minutes late.' as worst_periods_rule,
    map_block.map,
    coalesce(files.files, json('[]')) as files,
    data_coverage.coverage,
    decision.decision,
    coalesce(glossary.glossary, json('[]')) as glossary,
    latest_day.latest_day,
    commuter_rail.commuter_rail,
    survey.survey,
    charts.charts
from meta
cross join tiles
cross join lines
cross join worst_stations
cross join worst_periods
cross join map_block
cross join files
cross join data_coverage
cross join decision
cross join glossary
cross join latest_day
cross join commuter_rail
cross join survey
cross join charts
