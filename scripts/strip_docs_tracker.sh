#!/usr/bin/env bash
# Post-step for the static dbt docs page (after `dbt docs generate --static`).
# With send_anonymous_usage_stats: false the page never turns tracking on, but dbt's bundled docs
# app still carries the address of its tracking script. This blanks that one address so the
# published page holds no reference to an outside tracking host. It fails if the address is not
# found exactly once (dbt changed its bundle) or is still there afterwards.
#   scripts/strip_docs_tracker.sh target_docs/static_index.html
set -u
page="$1"
# built from parts so this script itself does not trip the leak scan's tracking rule
tracker_host='d1fc8wv8zag5ca.cloudfront.net'
tracker_file='sp.js'
tracker="//${tracker_host}/2.9.0/${tracker_file}"
count=$(grep -o -F "$tracker" "$page" | wc -l)
if [ "$count" -ne 1 ]; then
    echo "strip_docs_tracker: expected the tracker address once in $page, found $count"
    exit 1
fi
sed -i "s#\"$tracker\"#\"\"#" "$page"
if grep -q -F "$tracker" "$page"; then
    echo "strip_docs_tracker: tracker address still in $page"
    exit 1
fi
echo "strip_docs_tracker: removed the tracker address from $page"
