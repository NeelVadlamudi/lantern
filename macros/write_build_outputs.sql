{#- on-run-end hook (dbt_project.yml).

    Totals in the build block count the nodes this invocation ran (dbt `results`):
    passed = success + pass, errored = error + fail, no_op = exposures (listed by dbt build but
    not executed). nodes_total = passed + warned + errored + skipped + no_op.

    1. Any invocation that ran models (dbt build / dbt run) records its `results` in
       audit.build_results: unique_id, resource_type, name, status, execution_time, failures,
       message. tests/assert_build_has_no_failures.sql reads that table.
    2. When this invocation built board_payload and nothing errored or failed, it also writes
       <out>/build_results.json (the same rows) and <out>/board_data.json: the board_payload row
       plus a `build` block put together here from `results` and the project `graph`.
       A failed model or test therefore leaves the previous board_data.json in place.
-#}
{% macro write_build_outputs(results) %}
    {%- if not execute or results | length == 0 -%}
        {{ return('select 1') }}
    {%- endif -%}

    {%- set ns = namespace(ran_models=false, payload_ok=false, problems=0) -%}
    {%- for res in results -%}
        {%- if res.node.resource_type == 'model' -%}{%- set ns.ran_models = true -%}{%- endif -%}
        {%- if res.node.name == 'board_payload' and res.status == 'success' -%}{%- set ns.payload_ok = true -%}{%- endif -%}
        {%- if res.status in ['error', 'fail', 'runtime error'] -%}{%- set ns.problems = ns.problems + 1 -%}{%- endif -%}
    {%- endfor -%}
    {%- if not ns.ran_models -%}
        {{ return('select 1') }}
    {%- endif -%}

    {%- set out_dir = env_var('MBTA_OUT_DIR', 'out') -%}

    {#- 1. results -> audit.build_results -#}
    {%- set value_rows = [] -%}
    {%- for res in results -%}
        {%- set failures = res.failures if res.failures is not none else 'null' -%}
        {%- set message = (res.message | string)[:500] if res.message is not none else '' -%}
        {%- do value_rows.append(
            "('" ~ res.node.unique_id ~ "', '" ~ res.node.resource_type ~ "', '" ~ res.node.name ~ "', '"
            ~ (res.status | string) ~ "', " ~ (res.execution_time | round(3)) ~ ", " ~ failures ~ ", '"
            ~ message | replace("'", "''") ~ "')"
        ) -%}
    {%- endfor -%}
    {%- call statement('build_results_table') -%}
        create schema if not exists audit;
        create or replace table audit.build_results (
            invocation_id varchar,
            generated_at timestamp,
            unique_id varchar,
            resource_type varchar,
            name varchar,
            status varchar,
            execution_time double,
            failures bigint,
            message varchar
        );
        insert into audit.build_results
        select '{{ invocation_id }}', current_timestamp at time zone 'UTC', *
        from (values {{ value_rows | join(', ') }});
    {%- endcall -%}
    {%- do adapter.commit() -%}

    {%- if not ns.payload_ok or ns.problems > 0 -%}
        {%- do log("board_data.json not written: board_payload did not run in this invocation or "
            ~ ns.problems ~ " node(s) errored or failed", info=true) -%}
        {{ return('select 1') }}
    {%- endif -%}

    {#- 2. build block from results + graph -#}
    {%- set status_of = {} -%}
    {%- set test_status = {'pass': 0, 'warn': 0, 'fail': 0, 'error': 0, 'skipped': 0} -%}
    {%- set warned = [] -%}
    {%- set ns2 = namespace(tests_total=0, passed=0, warned=0, errored=0, skipped=0, no_op=0) -%}
    {%- set nodes_by_type = {'model': 0, 'test': 0, 'seed': 0, 'snapshot': 0} -%}
    {%- for res in results -%}
        {%- do status_of.update({res.node.unique_id: res.status | string}) -%}
        {%- set rt = res.node.resource_type | string -%}
        {%- do nodes_by_type.update({rt: nodes_by_type.get(rt, 0) + 1}) -%}
        {%- set rs = res.status | string -%}
        {%- if rs in ['success', 'pass'] -%}{%- set ns2.passed = ns2.passed + 1 -%}
        {%- elif rs == 'warn' -%}{%- set ns2.warned = ns2.warned + 1 -%}
        {%- elif rs in ['error', 'fail', 'runtime error'] -%}{%- set ns2.errored = ns2.errored + 1 -%}
        {%- elif rs == 'skipped' -%}{%- set ns2.skipped = ns2.skipped + 1 -%}
        {%- else -%}{%- set ns2.no_op = ns2.no_op + 1 -%}
        {%- endif -%}
        {%- if res.node.resource_type == 'test' -%}
            {%- set ns2.tests_total = ns2.tests_total + 1 -%}
            {%- set st = res.status | string -%}
            {%- do test_status.update({st: test_status.get(st, 0) + 1}) -%}
            {%- if st == 'warn' -%}{%- do warned.append(res.node.name) -%}{%- endif -%}
        {%- endif -%}
    {%- endfor -%}

    {%- set layer_order = ['staging', 'intermediate', 'marts', 'exports'] -%}
    {%- set models = {} -%}
    {%- set ns3 = namespace(snapshots=0, seeds=0) -%}
    {%- for node in graph.nodes.values() -%}
        {%- if node.resource_type == 'model' and node.package_name == project_name -%}
            {%- do models.update({node.unique_id: node}) -%}
        {%- elif node.resource_type == 'snapshot' -%}
            {%- set ns3.snapshots = ns3.snapshots + 1 -%}
        {%- elif node.resource_type == 'seed' -%}
            {%- set ns3.seeds = ns3.seeds + 1 -%}
        {%- endif -%}
    {%- endfor -%}

    {%- set layer_of = {} -%}
    {%- for uid, node in models.items() -%}
        {%- do layer_of.update({uid: node.fqn[1] if node.fqn | length > 2 else 'root'}) -%}
    {%- endfor -%}

    {%- set edge_counts = {} -%}
    {%- set model_edges = [] -%}
    {%- for uid, node in models.items() -%}
        {%- for dep in node.depends_on.nodes -%}
            {%- if dep in models -%}
                {%- set key = layer_of[dep] ~ '|' ~ layer_of[uid] -%}
                {%- do model_edges.append({'from': models[dep].name, 'to': node.name}) -%}
            {%- elif dep.startswith('source.') -%}
                {%- set key = 'sources|' ~ layer_of[uid] -%}
            {%- elif dep.startswith('seed.') -%}
                {%- set key = 'seeds|' ~ layer_of[uid] -%}
            {%- else -%}
                {%- set key = none -%}
            {%- endif -%}
            {%- if key is not none -%}
                {%- do edge_counts.update({key: edge_counts.get(key, 0) + 1}) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endfor -%}
    {%- set layer_edges = [] -%}
    {%- for key in edge_counts.keys() | sort -%}
        {%- set parts = key.split('|') -%}
        {%- do layer_edges.append({'from': parts[0], 'to': parts[1], 'count': edge_counts[key]}) -%}
    {%- endfor -%}

    {%- set by_layer = {} -%}
    {%- set contracted = [] -%}
    {%- set incremental = [] -%}
    {%- set external = [] -%}
    {%- for node in models.values() | sort(attribute='name') -%}
        {%- set layer = layer_of[node.unique_id] -%}
        {%- set enforced = (node.config.contract or {}).get('enforced', false) | default(false) -%}
        {%- if layer not in by_layer -%}{%- do by_layer.update({layer: []}) -%}{%- endif -%}
        {%- do by_layer[layer].append({
            'name': node.name,
            'materialized': node.config.materialized,
            'contract': enforced is true,
            'status': status_of.get(node.unique_id),
            'docs_anchor': '#!/model/' ~ node.unique_id
        }) -%}
        {%- if enforced -%}{%- do contracted.append(node.name) -%}{%- endif -%}
        {%- if node.config.materialized == 'incremental' -%}{%- do incremental.append(node.name) -%}{%- endif -%}
        {%- if node.config.materialized == 'external' -%}{%- do external.append(node.name) -%}{%- endif -%}
    {%- endfor -%}

    {%- set models_by_layer = {} -%}
    {%- set layer_anchors = {} -%}
    {%- for layer in layer_order -%}
        {%- do models_by_layer.update({layer: by_layer.get(layer, []) | length}) -%}
        {%- do layer_anchors.update({layer: by_layer.get(layer, []) | map(attribute='docs_anchor') | list}) -%}
    {%- endfor -%}

    {%- set now_utc = modules.datetime.datetime.now(modules.pytz.utc) -%}
    {%- set build = {
        'generated_at_utc': now_utc.strftime('%Y-%m-%dT%H:%M:%S.%fZ'),
        'dbt_version': dbt_version,
        'elapsed_seconds': ((now_utc - run_started_at).total_seconds()) | round(1),
        'nodes_total': results | length,
        'passed': ns2.passed,
        'warned': ns2.warned,
        'errored': ns2.errored,
        'skipped': ns2.skipped,
        'no_op': ns2.no_op,
        'nodes_by_type': nodes_by_type,
        'models_total': models | length,
        'models_by_layer': models_by_layer,
        'snapshots': ns3.snapshots,
        'seeds': ns3.seeds,
        'tests_total': ns2.tests_total,
        'tests_passed': test_status['pass'],
        'tests_warned': test_status['warn'],
        'tests_failed': test_status['fail'] + test_status['error'],
        'tests_skipped': test_status['skipped'],
        'warned_tests': warned | sort,
        'contracted_models': contracted | sort,
        'incremental_models': incremental | sort,
        'external_models': external | sort,
        'sources': graph.sources | length,
        'exposures': graph.exposures | length,
        'semantic_models': (graph.semantic_models or {}) | length,
        'metrics': (graph.metrics or {}) | length,
        'layer_edges': layer_edges,
        'model_edges': model_edges | sort(attribute='to') | sort(attribute='from'),
        'docs': {
            'index': 'dbt/index.html',
            'overview_anchor': '#!/overview',
            'lineage_anchor': '#!/overview?g_v=1',
            'layers': layer_anchors
        },
        'models': by_layer
    } -%}

    {%- set payload_node = models['model.' ~ project_name ~ '.board_payload'] -%}
    {%- set payload = api.Relation.create(
        database=payload_node.database, schema=payload_node.schema, identifier=payload_node.alias
    ) -%}

    {%- call statement('write_board_files') -%}
        copy (
            select * exclude (invocation_id, generated_at) from audit.build_results order by unique_id
        ) to '{{ out_dir }}/build_results.json' (format json, array true);
        copy (
            select
                meta,
                tiles,
                lines,
                worst_stations,
                worst_periods,
                worst_periods_rule,
                map,
                files,
                json('{{ tojson(build) | replace("'", "''") }}') as build,
                coverage,
                glossary
            from {{ payload }}
        ) to '{{ out_dir }}/board_data.json' (format json);
    {%- endcall -%}
    {%- do log("wrote " ~ out_dir ~ "/board_data.json and " ~ out_dir ~ "/build_results.json", info=true) -%}
    {{ return('select 1') }}
{% endmacro %}
