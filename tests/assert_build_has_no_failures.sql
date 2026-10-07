{{ config(enabled=var('check_build', false), tags=['post_build']) }}
-- The last dbt build/run recorded no errored or failed node (audit.build_results, written by the
-- on-run-end hook in macros/write_build_outputs.sql). A test cannot see the results of the
-- invocation it runs in, so run it right after the build:
--     dbt build ... && dbt test --select assert_build_has_no_failures --vars '{check_build: true}'
select unique_id, status, failures, message
from audit.build_results
where status in ('error', 'fail', 'runtime error', 'skipped')
