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
                'cause_dominance_ratio', cast({{ var('cause_dominance_ratio') }} as double)
            ),
            'method', 'Actual arrival-to-arrival times between stops are compared to the published'
            || ' schedule for every subway train, and actual gaps between trains to scheduled gaps.'
            || ' Stations are weighted by fare-gate entries for the same time of day.',
            'disclaimer', 'Public MBTA data. Live positions from the MBTA V3 API. Not affiliated with the MBTA.',
            'attribution', 'Data provided by MassDOT / MBTA under the MassDOT Developers License Agreement.'
        ) as meta
    from sources
    cross join service_window
    cross join rider_basis
    cross join row_counts
    cross join holidays
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

-- decision metrics (rider time lost, segments, buffer, getting worse, schedule or service) ---

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
                'avg_weekday_rider_time_lost_seconds', avg_weekday_rider_time_lost_seconds,
                'avg_weekday_rider_time_lost_label', avg_weekday_rider_time_lost_label,
                'share_of_segment_loss', share_of_segment_loss,
                'avg_excess_travel_seconds', avg_excess_travel_seconds,
                'avg_excess_travel_label', avg_excess_travel_label,
                'buffer_seconds', buffer_seconds,
                'buffer_label', buffer_label,
                'buffer_index', buffer_index,
                'cause_class', cause_class
            )
            order by loss_rank
        )) as segments,
        sum(avg_weekday_rider_time_lost_seconds) as top_10_seconds
    from top_segment_rows
),

segment_totals as (
    select
        sum(greatest(avg_weekday_rider_time_lost_seconds, 0)) as positive_segment_seconds,
        count(*) as segments,
        count(*) filter (where has_rider_data) as segments_with_rider_data
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
                'delta_excess_seconds', delta_excess_seconds,
                'delta_excess_label', delta_excess_label,
                'loss_share_change', loss_share_change
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
                'delta_excess_seconds', delta_excess_seconds,
                'delta_excess_label', delta_excess_label,
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
            'rider_time_lost', json_object(
                'headline', rider_headline.tile,
                'is_estimate', true,
                'clamped_at_zero', false,
                'clamp_note', 'Not clamped: cells where trains ran closer together or faster than'
                || ' scheduled offset cells where they ran slower, so this is net time lost.',
                'weekly', coalesce(rider_weekly.weeks, json('[]'))
            ),
            'segments', json_object(
                'segments', segment_totals.segments,
                'segments_with_rider_data', segment_totals.segments_with_rider_data,
                'top_10', coalesce(top_segments.segments, json('[]')),
                'top_10_share_of_segment_loss',
                top_segments.top_10_seconds / nullif(segment_totals.positive_segment_seconds, 0),
                'top_10_share_rule', 'Average weekday rider-weighted loss of the 10 top segments divided'
                || ' by the sum of the positive losses of all segments (in-vehicle time only).'
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
    coalesce(glossary.glossary, json('[]')) as glossary
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
